#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/config.env" ]] || { echo "Нет config.env" >&2; exit 1; }
source "$SCRIPT_DIR/config.env"
[[ $EUID -eq 0 ]] || { echo "Запускайте от root: sudo $0" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
log() { echo ">>> $*"; }

apt-get install -y ufw fail2ban python3-systemd unattended-upgrades needrestart

# --- sshd: drop-in конфиг ------------------------------------------
# Аутентификацию сознательно НЕ трогаем: её задаёт провижининг при создании.
# MaxAuthTries 6 (дефолт), а не ниже: при ssh-агенте с пачкой ключей строгий
# лимит обрубает перебор ДО правильного ключа ("Too many authentication
# failures"). От брутфорса защищает fail2ban, а не эта цифра.
NEW_PORT="${SSH_PORT:-22}"
CUR_PORT="$( (sshd -T 2>/dev/null || true) | awk '/^port /{print $2; exit}')"
CUR_PORT="${CUR_PORT:-22}"

cat > /etc/ssh/sshd_config.d/60-hardening.conf <<EOF
Port ${NEW_PORT}
X11Forwarding no
MaxAuthTries 6
LoginGraceTime 30
ClientAliveInterval 600
ClientAliveCountMax 2

# Если образ провайдера пришёл с парольным входом и хотите его закрыть —
# раскомментируйте, убедившись, что ТЕКУЩАЯ сессия поднята по ключу:
#PermitRootLogin prohibit-password
#PasswordAuthentication no
#KbdInteractiveAuthentication no
EOF
sshd -t

# --- fail2ban: ваш IP вне подозрений ---------------------------------
# Агрессивный режим считает провалами и preauth-обрывы; если вы гоняли
# проверки без ключа, свежестартовавший fail2ban способен забанить сам
# источник прогона. Игнорируем IP, откуда прилетела установка.
CLIENT_IP=""
[[ -n "${SSH_CONNECTION:-}" ]] && CLIENT_IP="$(cut -d' ' -f1 <<<"$SSH_CONNECTION")"

mkdir -p /etc/fail2ban/jail.d
{
    echo "[DEFAULT]"
    [[ -n "$CLIENT_IP" ]] && echo "ignoreip = 127.0.0.1/8 ::1 ${CLIENT_IP}"
} > /etc/fail2ban/jail.d/00-ignoreip.local

# --- порядок операций вокруг порта критичен --------------------------
ufw default deny incoming
ufw default allow outgoing
ufw limit "${NEW_PORT}/tcp" comment 'SSH'

log "Переключение sshd на порт ${NEW_PORT}..."
if systemctl is-active --quiet ssh.socket; then
    # Сокет-активация: слушает systemd, директива Port на него не действует.
    # Пустой ListenStream= сбрасывает прежние сокеты, затем назначаем наш.
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/00-port.conf <<EOF
[Socket]
ListenStream=
ListenStream=${NEW_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
    systemctl try-restart ssh   # уже открытые сессии при этом живут
else
    systemctl reload ssh
fi
sleep 1
ss -tln | grep -q ":${NEW_PORT} " || { echo "!! никто не слушает ${NEW_PORT}" >&2; exit 1; }

[[ "$CUR_PORT" != "$NEW_PORT" ]] && ufw delete limit "${CUR_PORT}/tcp" >/dev/null 2>&1 || true
ufw --force enable
ufw status verbose

# --- fail2ban: journald, aggressive ----------------------------------
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
backend  = systemd
mode     = aggressive
port     = ${NEW_PORT}
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
bantime.maxtime = 1w
EOF
systemctl enable fail2ban >/dev/null
systemctl restart fail2ban

# Разбан источника установки: снимает возможный запрет, накопленный
# предыдущими прогонами/тестами (idempotent: несуществующий бан — не ошибка)
if [[ -n "$CLIENT_IP" ]]; then
    fail2ban-client set sshd unbanip "$CLIENT_IP" >/dev/null 2>&1 || true
fi

# --- автообновления --------------------------------------------------
printf '%s\n' \
    'APT::Periodic::Update-Package-Lists "1";' \
    'APT::Periodic::Unattended-Upgrade "1";' \
    > /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/51-unattended-hardening.conf <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# --- персистентный журнал --------------------------------------------
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-persistent.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
EOF
systemctl restart systemd-journald

# --- часовой пояс ----------------------------------------------------
if [[ -n "${TIMEZONE:-}" ]] && [[ "$(timedatectl show -p Timezone --value)" != "$TIMEZONE" ]]; then
    log "Часовой пояс → $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE"
fi

# --- swap ------------------------------------------------------------
if [[ "${CREATE_SWAP:-false}" == "true" ]] && ! swapon --show --noheadings | grep -q . && [[ ! -e /swapfile ]]; then
    ROOT_FS="$(findmnt -no FSTYPE /)"
    if [[ "$ROOT_FS" == "btrfs" || "$ROOT_FS" == "zfs" ]]; then
        log "Корень на $ROOT_FS — swapfile пропущен (другая процедура)"
    else
        SWAP_SIZE="${SWAP_SIZE:-2G}"
        log "Создаю swap ${SWAP_SIZE}..."
        fallocate -l "$SWAP_SIZE" /swapfile
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
        sysctl -q -p /etc/sysctl.d/99-swappiness.conf
    fi
fi

# --- сводка -----------------------------------------------------------
log "Финальная сводка:"
sshd -T | grep -E '^(port|passwordauthentication|permitrootlogin) '
ufw status verbose | head -5
fail2ban-client status sshd
swapon --show || true

SERVER_IP="$(hostname -I | awk '{print $1}')"
CONNECT_HINT="ssh root@${SERVER_IP}"
[[ "$NEW_PORT" != 22 ]] && CONNECT_HINT="ssh -p ${NEW_PORT} root@${SERVER_IP}" || true

cat <<EOF

✅ Hardening применён.
Подключение:  ${CONNECT_HINT}
Если порт меняли — обновите ~/.ssh/config на локальной машине.
⚠️ Не ретрайтесь чаще ~5 раз за полминуты: ufw limit начнёт рвать и вас.

Следующий шаг: бэкапы ВНЕ этого сервера (restic/borg).
EOF