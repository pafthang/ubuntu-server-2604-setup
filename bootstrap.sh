#!/usr/bin/env bash
set -euo pipefail

# === конфигурация ==================================================
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/pafthang/ubuntu-server-2604-setup/main}"
MODE="all"; KEY_URL="${KEY_URL:-}"; PORT="${SSH_PORT:-22}"
ASSUME_YES=0; SKIP_GATE=0; GATE_TIMEOUT=900

while [[ $# -gt 0 ]]; do case "$1" in
    all|packages|access|harden) MODE="$1" ;;
    --key-url)   KEY_URL="$2"; shift ;;
    --port)      PORT="$2"; shift ;;
    --timeout)   GATE_TIMEOUT="$2"; shift ;;
    --yes)       ASSUME_YES=1 ;;
    --skip-gate) SKIP_GATE=1 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
esac; shift; done

log() { echo -e "\033[1m[bootstrap]\033[0m $*"; }
die() { echo "[bootstrap][FATAL] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускайте от root"

# === откуда брать этапы ============================================
# ФИКС №1: через `curl | bash` файла-источника НЕТ, и ${BASH_SOURCE[0]}
# не определён вовсе. Обращение вида ${BASH_SOURCE[0]} под set -u валит
# скрипт — поэтому достаём через :- и считаем DIR осторожно.
SELF="${BASH_SOURCE[0]:-}"
DIR=""
if [[ -n "$SELF" && -f "$SELF" ]]; then
    DIR="$(cd "$(dirname "$SELF")" && pwd)"
fi

if [[ -n "$DIR" && -f "$DIR/10-packages.sh" ]]; then
    log "Использую локальные файлы из $DIR"
else
    STAGE="$(mktemp -d /tmp/infra-bootstrap.XXXXXX)"
    for f in 10-packages.sh 20-ssh-access.sh 30-hardening.sh; do
        curl -fsSL "$REPO_BASE/$f" -o "$STAGE/$f" || die "Не скачался $f"
    done
    chmod +x "$STAGE"/*.sh
    # ФИКС №2: этапы жёстко требуют соседний config.env. При piped-запуске
    # его неоткуда взять — генерируем из фактических значений CLI/env.
    # %q квотирует спецсимволы (например & в query-string URL),
    # чтобы файл корректно читался обратно через source.
    {
        printf 'SSH_PORT=%q\n'     "$PORT"
        printf 'TIMEZONE=%q\n'     "${TIMEZONE:-}"
        printf 'CREATE_SWAP=%q\n'  "${CREATE_SWAP:-false}"
        printf 'SWAP_SIZE=%q\n'    "${SWAP_SIZE:-2G}"
        if [[ -n "${KEY_URL:-}" ]]; then
            printf 'KEY_URL=%q\n'  "$KEY_URL"
        fi
    } > "$STAGE/config.env"
    DIR="$STAGE"
fi

export SSH_PORT="$PORT"
if [[ -n "${KEY_URL:-}" ]]; then export KEY_URL; fi   # ФИКС №3: if вместо unprotected &&

# === чтение подтверждения строго с TTY =============================
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
log "(fish станет активной со следующего логина)"

log "Этап 2/3: закладка SSH-ключей"
run "$DIR/20-ssh-access.sh"

GATE_SINCE=$(date +%s)
confirmed=0

if (( SKIP_GATE )); then
    log "--skip-gate: пропускаю проверку доступа (только для тестов/CI!)"
    confirmed=1
fi

cat <<EOF

╔═════════════════════════════════════════════════════════════╗
║  ПРОВЕРКА ДОСТУПА. Сейчас я жду, что вы:                    ║
║                                                             ║
║    1. откроете ВТОРОЙ терминал                              ║
║    2. выполните:  ssh root@$(hostname -I | awk '{print $1}')║
║                                                             ║
║  Вход детектируется автоматически по журналу.               ║
║  Таймаут: ${GATE_TIMEOUT} сек.                              ║
╚═════════════════════════════════════════════════════════════╝
EOF

while (( ! confirmed && SECONDS < GATE_TIMEOUT )); do
    if journalctl --quiet --since "@$GATE_SINCE" \
         | grep -q 'Accepted publickey'; then
        confirmed=1
        log "✓ Зарегистрирован успешный вход по ключу"
        break
    fi
    sleep 5
done

(( confirmed )) || die "Повторного входа по ключу не было за ${GATE_TIMEOUT} сек.
Hardening НЕ запущен — система доступна как есть.
Проверьте вход вручную, затем: sudo bash $0 harden"

confirm "Вход по ключу работает. Закрыть пароли, включить firewall/fail2ban?" \
    || { log "Остановлено пользователем. Позже: sudo bash $0 harden"; exit 0; }

log "Этап 3/3: hardening"
run "$DIR/30-hardening.sh"

cat <<EOF

🎉 Автономная настройка завершена полностью.
Подключение: ssh -p ${PORT} root@$(hostname -I | awk '{print $1}')
EOF