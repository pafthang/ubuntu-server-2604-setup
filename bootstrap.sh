#!/usr/bin/env bash
set -euo pipefail

# === конфигурация ==================================================
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/YOU/infra-bootstrap/main}"
# ^ подставьте хэш коммита вместо main для воспроизводимости

MODE="all"; KEY_URL="${KEY_URL:-}"; PORT="${SSH_PORT:-22}"
ASSUME_YES=0; GATE_TIMEOUT=900   # сколько ждать повторный вход по ключу

while [[ $# -gt 0 ]]; do case "$1" in
    all|packages|access|harden) MODE="$1" ;;
    --key-url) KEY_URL="$2"; shift ;;
    --port)    PORT="$2"; shift ;;
    --timeout) GATE_TIMEOUT="$2"; shift ;;
    --yes)     ASSUME_YES=1 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
esac; shift; done

log() { echo -e "\033[1m[bootstrap]\033[0m $*"; }
die() { echo "[bootstrap][FATAL] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускайте от root"

# === откуда брать этапы ============================================
# Локальная копия рядом со скриптом важнее сети (удобно для теста в LXC/VM);
# иначе — подтягиваем четыре файла с REPO_BASE.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$DIR/10-packages.sh" ]]; then
    log "Использую локальные файлы из $DIR"
else
    STAGE="/tmp/infra-bootstrap.$RANDOM"
    mkdir -p "$STAGE"
    for f in config.env.example 10-packages.sh 20-ssh-access.sh 30-hardening.sh; do
        curl -fsSL "$REPO_BASE/$f" -o "$STAGE/$f" || die "Не скачался $f"
    done
    chmod +x "$STAGE"/*.sh
    DIR="$STAGE"
fi

# настройки поверх файлов: из аргументов → в config.env этапов
export SSH_PORT="$PORT"
[[ -n "$KEY_URL" ]] && export KEY_URL

# === чтение подтверждения строго с TTY (не ломается от curl|bash) ==
TTY_OK=1; exec 3</dev/tty 2>/dev/null || TTY_OK=0
confirm() {
    if (( ASSUME_YES )); then log "--yes: пропускаю подтверждение"; return 0; fi
    (( TTY_OK )) || die "Нет TTY для подтверждения — перезапустите с флагом --yes"
    local ans; read -r -p "$1 [y/N] " ans <&3
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

run() { log "▶ этап: $(basename "$1")"; bash "$1"; }

case "$MODE" in
packages) run "$DIR/10-packages.sh"; exit 0 ;;
access)   run "$DIR/20-ssh-access.sh"; exit 0 ;;
harden)   run "$DIR/30-hardening.sh"; exit 0 ;;
esac

# ============================ ПОЛНЫЙ ПРОГОН ========================

log "Этап 1/3: пакеты и инструменты"
run "$DIR/10-packages.sh"
log "(fish станет активной со следующего логина — текущая сессия этому не мешает)"

log "Этап 2/3: закладка SSH-ключей"
run "$DIR/20-ssh-access.sh"

# --- ⚠️ ГЕЙТ ДОСТУПА -----------------------------------------------
# Отсечка времени ДО запуска ожидания: любой вход по ключу после неё —
# доказательство, что новая конфигурация принимает ключи на практике.
GATE_SINCE=$(date +%s)

cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║  ПРОВЕРКА ДОСТУПА. Сейчас я жду, что вы:                     ║
║                                                              ║
║    1. откроете ВТОРОЙ терминал                               ║
║    2. выполните:  ssh root@$(hostname -I | awk '{print $1}') ║
║                                                              ║
║  Я детектирую этот вход автоматически по системному журналу. ║
║  Таймаут ожидания: ${GATE_TIMEOUT} сек.                      ║
╚══════════════════════════════════════════════════════════════╝
EOF

confirmed=0
while (( SECONDS < GATE_TIMEOUT )); do
    if journalctl --quiet --since "@$GATE_SINCE" \
         | grep -q 'Accepted publickey'; then
        confirmed=1
        log "✓ Зарегистрирован успешный вход по ключу"
        break
    fi
    sleep 5
done

(( confirmed )) || die "Повторного входа по ключу не было за ${GATE_TIMEOUT} сек.
Это подозрительно (или сессия простаивала). Hardening НЕ запущен —
проверьте доступ вручную, затем запустите: sudo bash $0 harden"

confirm "Вход по ключу работает. Закрыть пароли, включить firewall/fail2ban?" \
    || { log "Остановлено пользователем. Продолжить позже: sudo bash $0 harden"; exit 0; }

log "Этап 3/3: hardening"
run "$DIR/30-hardening.sh"

cat <<EOF

🎉 Автономная настройка завершена полностью.
Подключение: ssh -p ${PORT} root@$(hostname -I | awk '{print $1}')
Проверки из README: ufw status verbose; fail2ban-client status sshd
EOF