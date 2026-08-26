#!/usr/bin/env bash
set -euo pipefail

# === общая шапка ==================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/config.env" ]] || { echo "Нет config.env — выполните: cp config.env.example config.env" >&2; exit 1; }
source "$SCRIPT_DIR/config.env"
[[ $EUID -eq 0 ]] || { echo "Запускайте от root: sudo $0" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
log() { echo ">>> $*"; }
tool() { command -v "$1" >/dev/null; }

# ==================================================================
log "Обновление системы..."
apt-get update
apt-get upgrade -y

# Примечание: ufw и fail2ban ставятся в 30-hardening.sh вместе со своей
# конфигурацией. Причина: свежеустановленный fail2ban включает дефолтный
# джейл на несуществующий /var/log/auth.log и сыплет ошибками в лог.
PACKAGES=(
    # сеть и диагностика
    curl wget git rsync jq
    netcat-openbsd dnsutils mtr-tiny traceroute whois
    # шелл и удобства
    fish
    bash-completion less tree file fzf
    # мониторинг
    htop ncdu iotop sysstat lsof
    # архивы
    unzip zip p7zip-full
    # базы для сторонних репозиториев + страховочный редактор
    man-db ca-certificates gnupg apt-transport-https
    nano
)

log "Установка пакетов..."
apt-get install -y --no-install-recommends "${PACKAGES[@]}"

# fzf в репозитории 24.04 старше 0.48, а интеграция с fish требует 0.48+.
# Если после установки Ctrl+R/Ctrl+T в fish молчат — раскомментируйте:
# apt-get install -y software-properties-common
# add-apt-repository -y ppa:fzf/ppa
# apt-get install -y --only-upgrade fzf

# === инструменты вне apt: apt -> snap -> официальный бинарник ======

install_zellij() {
    ZJ_VER="0.42.2"   # сверьте актуальный релиз
    curl -fsSL -o /tmp/zellij.tgz \
        "https://github.com/zellij-org/zellij/releases/download/v${ZJ_VER}/zellij-x86_64-unknown-linux-musl.tar.gz"
    tar -xzf /tmp/zellij.tgz -C /usr/local/bin zellij
    rm -f /tmp/zellij.tgz
}

install_micro() {
    ( cd /tmp && curl -fsSL https://getmic.ro | bash )
    mv -f /tmp/micro /usr/local/bin/micro
}

install_helix() {
    HX_VER="25.07"    # сверьте актуальный релиз
    mkdir -p /opt/helix
    curl -fsSL -o /tmp/helix.tgz \
        "https://github.com/helix-editor/helix/releases/download/${HX_VER}/helix-${HX_VER}-x86_64-linux.tar.gz"
    tar -xzf /tmp/helix.tgz -C /opt/helix --strip-components=1
    rm -f /tmp/helix.tgz
    ln -sf /opt/helix/hx /usr/local/bin/hx
}

snap_try() { command -v snap >/dev/null 2>&1 && snap install "$@" >/dev/null 2>&1; }

log "Установка zellij..."
tool zellij || { apt-get install -y zellij >/dev/null 2>&1 || snap_try zellij || install_zellij; }

log "Установка micro..."
tool micro || { snap_try micro --classic || install_micro; }

log "Установка helix..."
tool hx || { apt-get install -y helix >/dev/null 2>&1 || snap_try helix --classic || install_helix; }

# === конфигурация ==================================================

log "Редактор по умолчанию — micro..."
# для bash-сессий
echo 'export EDITOR=micro VISUAL=micro SUDO_EDITOR=micro' > /etc/profile.d/50-editor.sh
# для fish-сессий (profile.d fish не читает)
mkdir -p /etc/fish/conf.d
cat > /etc/fish/conf.d/30-editor.fish <<'EOF'
set -gx EDITOR micro
set -gx VISUAL micro
set -gx SUDO_EDITOR micro
set -g fish_greeting
EOF
# чтобы sudoedit/git commit/crontab -e выбирали micro автоматически
update-alternatives --install /usr/bin/editor editor "$(command -v micro)" 100 >/dev/null

log "Настройка fish: HELIX_RUNTIME + fzf..."
echo 'set -gx HELIX_RUNTIME /opt/helix/runtime' > /etc/fish/conf.d/40-helix-runtime.fish
cat > /etc/fish/conf.d/90-fzf.fish <<'EOF'
if status is-interactive; and type -q fzf; and fzf --fish >/dev/null 2>&1
    fzf --fish | source
end
EOF

# запасные биндинги, если вдруг окажетесь внутри bash (recovery и т.п.)
grep -q '# >>> infra-bootstrap' /root/.bashrc 2>/dev/null || cat >> /root/.bashrc <<'EOF'
# >>> infra-bootstrap >>>
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && . /usr/share/doc/fzf/examples/key-bindings.bash
# <<< infra-bootstrap <<<
EOF

log "fish становится login-shell для root..."
FISH_BIN="$(command -v fish)"
grep -qxF "$FISH_BIN" /etc/shells || echo "$FISH_BIN" >> /etc/shells
chsh -s "$FISH_BIN" root

apt-get autoremove -y
apt-get clean

log "Готово. Перелогиньтесь по SSH — окажетесь в fish. Затем: sudo ./20-ssh-access.sh"
log "Итог:"
for c in fish zellij micro hx fzf nano; do
    printf '  %-8s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo 'НЕ НАЙДЕН')"
done