#!/usr/bin/env bash
#
# ubuntu-server-2604-setup — этап 10/30: система, пакеты, инструменты
#
# Идемпотентен: обрыв связи лечится повторным запуском той же команды —
# выполненное пропускается за секунды, недоделанное добивается.
# Философия отказов ГРОМКАЯ: видна каждая попытка, тихих зависаний нет.
set -euo pipefail
trap 'echo "[10-packages][FATAL] авария в строке ${LINENO} файла $0" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$SCRIPT_DIR/config.env" ]] || {
    echo "[FATAL] Нет $SCRIPT_DIR/config.env — скопируйте из примера или запускайте через bootstrap.sh" >&2
    exit 1
}
source "$SCRIPT_DIR/config.env"
[[ $EUID -eq 0 ]] || { echo "[FATAL] Запускайте от root: sudo $0" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log()  { echo ">>> $*"; }
tool() { command -v "$1" >/dev/null; }

# --- архитектура ---------------------------------------------------
BIN_ARCH=""
case "$(dpkg --print-architecture)" in
    amd64) BIN_ARCH="x86_64" ;;
    arm64) BIN_ARCH="aarch64" ;;
esac
[[ -n "$BIN_ARCH" ]] || {
    echo "[FATAL] Архитектура $(dpkg --print-architecture) не поддерживается (бинарные релизы: amd64/arm64)" >&2
    exit 1
}

# === 1. Система ====================================================
log "Обновление системы..."
apt-get update
apt-get upgrade -y

# === 2. Пакеты из репозитория ======================================
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
    # базы для сторонних источников + страховочный редактор
    man-db ca-certificates gnupg apt-transport-https
    nano
)

log "Установка пакетов (--no-install-recommends)..."
apt-get install -y --no-install-recommends "${PACKAGES[@]}"

# jq установлен выше и используется ниже (GitHub API) — порядок фаз гарантирует наличие

# === 3. Инструменты вне apt ========================================
install_zellij() {
    local ver
    ver="$(curl -fsSL https://api.github.com/repos/zellij-org/zellij/releases/latest | jq -r .tag_name)"
    ver="${ver#v}"
    log "zellij ${ver}: скачивание бинарника (${BIN_ARCH})..."
    curl -fL --retry 3 -o /tmp/zellij.tgz \
        "https://github.com/zellij-org/zellij/releases/download/v${ver}/zellij-${BIN_ARCH}-unknown-linux-musl.tar.gz"
    tar -xzf /tmp/zellij.tgz -C /usr/local/bin zellij
    rm -f /tmp/zellij.tgz
    log "zellij ${ver}: установлен"
}

install_micro() {
    log "micro: скачивание официальным установщиком..."
    mkdir -p /tmp/micro-install
    ( cd /tmp/micro-install && curl -fsSL https://getmic.ro | bash )
    mv -f /tmp/micro-install/micro /usr/local/bin/micro
    rm -rf /tmp/micro-install
    log "micro: установлен ($(micro --version | head -n1))"
}

install_helix() {
    local ver
    ver="$(curl -fsSL https://api.github.com/repos/helix-editor/helix/releases/latest | jq -r .tag_name)"
    ver="${ver#v}"
    log "helix ${ver}: скачивание архива (${BIN_ARCH}, формат .tar.xz)..."
    curl -fL --retry 3 -o /tmp/helix.tar.xz \
        "https://github.com/helix-editor/helix/releases/download/${ver}/helix-${ver}-${BIN_ARCH}-linux.tar.xz"
    mkdir -p /opt/helix
    tar -xJf /tmp/helix.tar.xz -C /opt/helix --strip-components=1
    rm -f /tmp/helix.tar.xz
    ln -sf /opt/helix/hx /usr/local/bin/hx
    log "helix ${ver}: установлен"
    HX_SOURCE="tarball"
}

SNAP_TIMEOUT=120

log "Установка zellij..."
tool zellij || {
    apt-get install -y zellij \
        || timeout "$SNAP_TIMEOUT" snap install zellij --classic \
        || install_zellij
}

log "Установка micro..."
tool micro || {
    snap install micro --classic \
        || install_micro
}

HX_SOURCE="repo"
log "Установка helix..."
tool hx || {
    apt-get install -y helix \
        || timeout "$SNAP_TIMEOUT" snap install helix --classic \
        || install_helix
}

# === 4. Конфигурация ===============================================

# --- fish как login-shell для root ---------------------------------
# Сам chsh идемпотентен, но проверяем явно: повторный прогон даёт «уже fish»,
# а не лишнее телодвижение. Путь дублируем в /etc/shells — некоторые PAM-стеки
# и утилиты типа usermod сверяются с ним даже для root.
FISH_BIN="$(command -v fish)"
CURRENT_SHELL="$(getent passwd root | cut -d: -f7)"
if [[ "$CURRENT_SHELL" == "$FISH_BIN" ]]; then
    log "Login-shell root уже fish (${FISH_BIN})"
else
    grep -qxF "$FISH_BIN" /etc/shells || echo "$FISH_BIN" >> /etc/shells
    chsh -s "$FISH_BIN" root
    log "Login-shell root: ${CURRENT_SHELL} → ${FISH_BIN} (вступит в силу со СЛЕДУЮЩЕГО логина)"
fi

log "Редактор по умолчанию — micro (bash и fish, sudoedit/git/crontab)..."
echo 'export EDITOR=micro VISUAL=micro SUDO_EDITOR=micro' > /etc/profile.d/50-editor.sh

mkdir -p /etc/fish/conf.d
cat > /etc/fish/conf.d/30-editor.fish <<'EOF'
set -gx EDITOR micro
set -gx VISUAL micro
set -gx SUDO_EDITOR micro
set -g fish_greeting
EOF

update-alternatives --install /usr/bin/editor editor "$(command -v micro)" 100 >/dev/null
update-alternatives --set editor "$(command -v micro)"

if [[ "$HX_SOURCE" == "tarball" ]]; then
    log "HELIX_RUNTIME → /opt/helix/runtime (установка тарболлом)"
    cat > /etc/fish/conf.d/40-helix-runtime.fish <<'EOF'
set -gx HELIX_RUNTIME /opt/helix/runtime
EOF
fi

cat > /etc/fish/conf.d/90-fzf.fish <<'EOF'
if status is-interactive; and type -q fzf; and fzf --fish >/dev/null 2>&1
    fzf --fish | source
end
EOF