#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/config.env" ]] || { echo "Нет config.env" >&2; exit 1; }
source "$SCRIPT_DIR/config.env"
[[ $EUID -eq 0 ]] || { echo "Запускайте от root: sudo $0" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a   # needrestart рестартует сервисы сам, без TUI
log() { echo ">>> $*"; }

# Страховка от запуска вслепую: без ключа этот скрипт запрещает себе работу
[[ -s /root/.ssh/authorized_keys ]] || {
    echo "!! /root/.ssh/authorized_keys пуст. Сначала 20-ssh-access.sh и проверка входа!" >&2; exit 1;
}

apt-get install -y ufw fail2ban python3-systemd unattended-upgrades needrestart

# --- sshd: drop-in конфиг ------------------------------------------
NEW_PORT="${SSH_PORT:-22}"
CUR_PORT="$( (sshd -T 2>/dev/null || true) | awk '/^port /{print $2; exit}')"
CUR_PORT="${CUR_PORT:-22}"

cat > /etc/ssh/sshd_config.d/60-hardening.conf <<EOF
Port ${NEW_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 600
ClientAliveCountMax 2
EOF
sshd -t   # синтаксис проверяем ДО любых изменений сети

# --- порядок операций вокруг порта критичен ------------------------
# Правило нового порта добавляем ДО переключения sshd, чтобы разрывов не было;
# живые установленные соединения UFW не режет (state ESTABLISHED в conntrack).
ufw default deny incoming
ufw default allow outgoing
ufw limit "${NEW_PORT}/tcp" comment 'SSH'

log "Переключение sshd на порт ${NEW_PORT}..."
systemctl reload ssh
sleep 1
ss -tln | grep -q ":${NEW_PORT} " || { echo "!! sshd не слушает ${NEW_PORT} — проверьте вручную" >&2; exit 1; }

[[ "$CUR_PORT" != "$NEW_PORT" ]] && ufw delete limit "${CUR_PORT}/tcp" >/dev/null 2>&1 || true
ufw --force enable
ufw status verbose

# --- fail2ban: читаем напрямую из journald (в 24.04 нет auth.log!) --
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

# --- автообновления security ---------------------------------------
printf '%s\n' \
    'APT::Periodic::Update-Package-Lists "1";' \
    'APT::Periodic::Unattended-Upgrade "1";' \
    > /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/51-unattended-hardening.conf <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# --- персистентный журнал (по умолчанию логи живут в RAM и гибнут) -
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-persistent.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
EOF
systemctl restart systemd-journald

# --- часовой пояс ---------------------------------------------------
if [[ -n "${TIMEZONE:-}" ]] && [[ "$(timedatectl show -p Timezone --value)" != "$TIMEZONE" ]]; then
    log "Часовой пояс → $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE"
fi

# --- swap (для маленьких VPS; на btrfs/zfs делается иначе) ----------
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
        sysctl -q -p /etc/sysctx.d/99-swappiness.conf 2>/dev/null || sysctl -q -p /etc/sysctl.d/99-swappiness.conf
    fi
fi

# --- сводка ---------------------------------------------------------
log "Финальная сводка:"
sshd -T | grep -E '^(port|passwordauthentication|permitrootlogin) '
ufw status verbose | head -5
fail2ban-client status sshd | grep -E 'Currently banned|Total banned' || true
swapon --show || true

cat <<EOF

✅ Hardening применён.
Вход теперь ТОЛЬКО:  ssh -p ${NEW_PORT} root@$(hostname -I | awk '{print $1}')
Если порт меняли — обновите его в ~/.ssh/config на локальной машине:

  Host myserver
      HostName <ip>
      User root
      Port ${NEW_PORT}

Следующий шаг, который здесь не автоматизирован осознанно:
бэкапы ВНЕ этого сервера (restic/borg). Это важнее любого пунктa выше.
EOF