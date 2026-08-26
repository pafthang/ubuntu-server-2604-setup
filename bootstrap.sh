#!/usr/bin/env bash
#
# ubuntu-server-2604-setup — оркестратор первичной настройки сервера
# Этапы: 10-packages.sh → 20-ssh-access.sh → [ГЕЙТ] → 30-hardening.sh
#
# Работает в обоих режимах запуска:
#   curl -fsSL <url> | sudo bash -s -- all --key-url ...
#   sudo bash bootstrap.sh all --key-url ...
set -euo pipefail

# Авария перестаёт быть немой: точный файл и строка вместо тишины
trap 'echo "[bootstrap][FATAL] авария в ${BASH_SOURCE[0]}:${LINENO}" >&2' ERR

# === конфигурация ==================================================
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/pafthang/ubuntu-server-2604-setup/main}"
# ^ для воспроизводимости замените main на хэш коммита (см. README)

MODE="all"
KEY_URL="${KEY_URL:-}"
PORT="${SSH_PORT:-22}"
ASSUME_YES=0
SKIP_GATE=0
GATE_TIMEOUT=900   # секунд ожидания второго входа по ключу

while [[ $# -gt 0 ]]; do case "$1" in
    all|packages|access|harden) MODE="$1" ;;
    --key-url)   KEY_URL="$2"; shift ;;
    --port)      PORT="$2"; shift ;;
    --timeout)   GATE_TIMEOUT="$2"; shift ;;
    --yes)       ASSUME_YES=1 ;;
    --skip-gate) SKIP_GATE=1 ;;
    *) echo "Неизвестный аргумент: $1" >&2; echo \
       "Использование: bootstrap.sh [all|packages|access|harden] [--key-url URL] [--port N] [--timeout SEC] [--yes] [--skip-gate]" >&2; exit 1 ;;
esac; shift; done

# sanity-проверка входных данных до того, как что-то изменили
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "[bootstrap][FATAL] некорректный порт: '$PORT'" >&2; exit 1
fi

log() { echo -e "\033[1m[bootstrap]\033[0m $*"; }
die() { echo "[bootstrap][FATAL] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускайте от root"

# === откуда брать этапы ============================================
# Через `curl | bash` файла-источника НЕТ: BASH_SOURCE пуст, поэтому
# достаём элемент через :- и ветвимся, а не падаем под set -u.
SELF="${BASH_SOURCE[0]:-}"
DIR=""
if [[ -n "$SELF" && -f "$SELF" ]]; then
    DIR="$(cd "$(dirname "$SELF")" && pwd)"
fi

if [[ -n "$DIR" && -f "$DIR/10-packages.sh" ]]; then
    log "Использую локальные файлы этапов из $DIR"
else
    STAGE="$(mktemp -d /tmp/infra-bootstrap.XXXXXX)"
    log "Этапы не найдены рядом со скриптом — скачиваю в $STAGE"
    for f in 10-packages.sh 20-ssh-access.sh 30-hardening.sh; do
        curl -fSL --retry 3 "$REPO_BASE/$f" -o "$STAGE/$f" \
            || die "Не скачался $f"
        chmod +x "$STAGE/$f"
    done
    # Этапы требуют соседний config.env; в piped-режиме его неоткуда взять,
    # поэтому собираем из фактических значений CLI/env. %q квотирует
    # спецсимволы (например & в query-string), source прочитает обратно ровно.
    {
        printf 'SSH_PORT=%q\n'    "$PORT"
        printf 'TIMEZONE=%q\n'    "${TIMEZONE:-}"
        printf 'CREATE_SWAP=%q\n' "${CREATE_SWAP:-false}"
        printf 'SWAP_SIZE=%q\n'   "${SWAP_SIZE:-2G}"
        [[ -n "$KEY_URL" ]] && printf 'KEY_URL=%q\n' "$KEY_URL"
    } > "$STAGE/config.env"
    DIR="$STAGE"
fi

export SSH_PORT="$PORT"
[[ -n "$KEY_URL" ]] && export KEY_URL

# === подтверждения: строго с TTY (curl | bash занимает stdin) =======
TTY_OK=1
exec 3</dev/tty 2>/dev/null || TTY_OK=0

confirm() {
    (( ASSUME_YES )) && { log "--yes: пропускаю подтверждение"; return 0; }
    if (( ! TTY_OK )); then
        die "Нет TTY для подтверждения — перезапустите с флагом --yes"
    fi
    local ans
    read -r -p "$1 [y/N] " ans <&3
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

run() {
    log "▶ этап: $(basename "$1")"
    bash "$1"
}

case "$MODE" in
    packages) run "$DIR/10-packages.sh"; exit 0 ;;
    access)   run "$DIR/20-ssh-access.sh"; exit 0 ;;
    harden)   run "$DIR/30-hardening.sh"; exit 0 ;;
esac

# ============================ ПОЛНЫЙ ПРОГОН ========================

log "Этап 1/3: пакеты и инструменты"
run "$DIR/10-packages.sh"
log "(fish станет активной со следующего логина — текущей bash-сессии это не мешает)"

log "Этап 2/3: закладка SSH-ключей"
run "$DIR/20-ssh-access.sh"

# --- ✋ ГЕЙТ ДОСТУПА ------------------------------------------------
# Отсечка времени ДО ожидания: считается только вход, случившийся ПОСЛЕ неё,
# ваш первый (давний) вход журналом не засчитается.
GATE_SINCE=$(date +%s)
confirmed=0

PORT_HINT="ssh root@$(hostname -I | awk '{print $1}')"
(( PORT != 22 )) && PORT_HINT="ssh -p ${PORT} root@$(hostname -I | awk '{print $1}')"

cat <<EOF

╔═════════════════════════════════════════════════════════════╗
║  ПРОВЕРКА ДОСТУПА. Пока идёт ожидание, вам нужно:           ║
║                                                             ║
║    1. открыть ВТОРОЙ терминал (эту сессию не закрывать!)    ║
║    2. выполнить:                                            ║
║         ${PORT_HINT}
║                                                             ║
║  Успешный вход детектируется автоматически по журналу sshd. ║
║  Таймаут ожидания: ${GATE_TIMEOUT} сек.                     ║
╚═════════════════════════════════════════════════════════════╝
EOF

if (( SKIP_GATE )); then
    log "--skip-gate: проверка входа пропущена (допустимо только в тестах/CI!)"
    confirmed=1
else
    LAST_TICK=$SECONDS
    while (( SECONDS < GATE_TIMEOUT )); do
        if journalctl --quiet --since "@$GATE_SINCE" 2>/dev/null \
             | grep -q 'Accepted publickey'; then
            confirmed=1
            log "✓ Зарегистрирован успешный вход по ключу"
            break
        fi
        if (( SECONDS - LAST_TICK >= 30 )); then
            LAST_TICK=$SECONDS
            echo "[bootstrap] …жду ШАГ 1 (вход по ключу): ${PORT_HINT}  (${SECONDS}/${GATE_TIMEOUT} сек)"
            echo "[bootstrap]   шаг 2 из баннера (отказ доступа) гейт НЕ двигает — он для вашей собственной проверки"
        fi
        sleep 5
    done
fi

if (( ! confirmed )); then
    die "Повторного входа по ключу не произошло за ${GATE_TIMEOUT} сек.
Hardening НЕ применён — система осталась доступна как была.
Проверьте вход вручную во втором терминале, затем перезапустите
эту же команду в режиме harden:  sudo bash <этот-скрипт> harden"
fi

confirm "Вход по ключу работает. Отключить пароли, включить firewall/fail2ban?" \
    || { log "Остановлено пользователем. Продолжить позже тем же способом."; exit 0; }

log "Этап 3/3: hardening"
run "$DIR/30-hardening.sh"

FINAL_HINT="${PORT_HINT}"
cat <<EOF

✅ Установка завершена.
Подключение в дальнейшем:  ${FINAL_HINT}
Вход теперь только по ключу.

Следующий шаг, который здесь не автоматизирован осознанно:
бэкапы ВНЕ этого сервера (restic/borg). Это важнее любого пункта выше.
EOF

log "Все этапы выполнены."