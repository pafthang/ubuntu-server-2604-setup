#!/usr/bin/env bash
#
# ubuntu-server-2604-setup — оркестратор первичной настройки сервера
# Этапы: 10-packages.sh → 20-hardening.sh
#
# Доступ (SSH-ключи, запрет паролей) СКРИПТАМИ НЕ УПРАВЛЯЕТСЯ —
# он настраивается при создании сервера (панель провайдера / cloud-init).
#
# Работает в обоих режимах запуска:
#   curl -fsSL <url> | sudo bash -s -- all
#   sudo bash bootstrap.sh all
set -euo pipefail

# Авария перестаёт быть немой: точный файл и строка вместо тишины
trap 'echo "[bootstrap][FATAL] авария в ${BASH_SOURCE[0]}:${LINENO}" >&2' ERR

# === конфигурация ==================================================
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/pafthang/ubuntu-server-2604-setup/main}"
# ^ для воспроизводимости замените main на хэш коммита (см. README)

MODE="all"
PORT="${SSH_PORT:-22}"
ASSUME_YES=0

while [[ $# -gt 0 ]]; do case "$1" in
    all|packages|harden) MODE="$1" ;;
    --port)              PORT="$2"; shift ;;
    --yes)               ASSUME_YES=1 ;;
    *) echo "Неизвестный аргумент: $1" >&2; echo \
       "Использование: bootstrap.sh [all|packages|harden] [--port N] [--yes]" >&2; exit 1 ;;
esac; shift; done

# sanity-проверка входных данных до того, как что-то изменили
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "[bootstrap][FATAL] некорректный порт: '$PORT'" >&2; exit 1
fi

log() { echo -e "\033[1m[bootstrap]\033[0m $*"; }
die() { echo "[bootstrap][FATAL] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускайте от root"

# Подтверждение строго до любых действий: в режиме all отказ пользователя
# оставляет систему нетронутой, тогда как отмена посреди прогона —
# наполовину настроенной.
if [[ "$MODE" == "all" && ! $ASSUME_YES ]]; then
    TTY_OK=1
    exec 3</dev/tty 2>/dev/null || TTY_OK=0
    if (( ! TTY_OK )); then
        die "Нет TTY для подтверждения — перезапустите с флагом --yes"
    fi
    echo "Будет выполнено:"
    echo "  1. apt update/upgrade, установка пакетов и инструментов"
    echo "  2. hardening: UFW, fail2ban, автообновления, персистентный журнал,"
    echo "     часовой пояс, swap; порт SSH → ${PORT}"
    echo "(доступ по ключу должен быть уже настроен при создании сервера)"
    read -r -p "Продолжить? [y/N] " ans <&3
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "Остановлено пользователем."
fi

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
    STAGE="$(mktemp -d /tmp/ubuntu-server-2604-setup.XXXXXX)"
    log "Этапы не найдены рядом со скриптом — скачиваю в $STAGE"
    for f in 10-packages.sh 20-hardening.sh; do
        curl -fSL --retry 3 "$REPO_BASE/$f" -o "$STAGE/$f" \
            || die "Не скачался $f"
        chmod +x "$STAGE/$f"
    done
    # Этапам нужен соседний config.env; в piped-режиме его неоткуда взять,
    # собираем из фактических значений CLI/env. %q квотирует спецсимволы,
    # source прочитает обратно ровно.
    {
        printf 'SSH_PORT=%q\n'    "$PORT"
        printf 'TIMEZONE=%q\n'    "${TIMEZONE:-}"
        printf 'CREATE_SWAP=%q\n' "${CREATE_SWAP:-false}"
        printf 'SWAP_SIZE=%q\n'   "${SWAP_SIZE:-2G}"
    } > "$STAGE/config.env"
    DIR="$STAGE"
fi

export SSH_PORT="$PORT"

run() {
    log "▶ этап: $(basename "$1")"
    bash "$1"
}

case "$MODE" in
    packages) run "$DIR/10-packages.sh";  exit 0 ;;
    harden)   run "$DIR/20-hardening.sh"; exit 0 ;;
esac

# ============================ ПОЛНЫЙ ПРОГОН ========================

log "Этап 1/2: пакеты и инструменты"
run "$DIR/10-packages.sh"
log "(fish станет активной со следующего логина — текущей bash-сессии это не мешает)"

log "Этап 2/2: hardening"
run "$DIR/20-hardening.sh"

CONNECT_HINT="ssh root@$(hostname -I | awk '{print $1}')"
(( PORT != 22 )) && CONNECT_HINT="ssh -p ${PORT} root@$(hostname -I | awk '{print $1}')" || true

cat <<EOF

✅ Установка завершена.
Подключение в дальнейшем:  ${CONNECT_HINT}
Доступ (ключи/пароли) считаем настроенным при создании сервера.

Следующий шаг, который здесь не автоматизирован осознанно:
бэкапы ВНЕ этого сервера (restic/borg). Это важнее любого пункта выше.
EOF

log "Все этапы выполнены."