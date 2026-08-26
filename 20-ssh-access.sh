#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/config.env" ]] || { echo "Нет config.env" >&2; exit 1; }
source "$SCRIPT_DIR/config.env"
[[ $EUID -eq 0 ]] || { echo "Запускайте от root: sudo $0" >&2; exit 1; }
log() { echo ">>> $*"; }

# Источник ключей: аргумент командной строки важнее KEY_URL
SRC="${1:-${KEY_URL:-}}"
if [[ -z "$SRC" ]]; then
    echo "Не указан источник публичных ключей. Любой из вариантов:" >&2
    echo '  • в config.env:  KEY_URL="https://github.com/<user>.keys"' >&2
    echo "  • аргументом:    sudo $0 https://github.com/<user>.keys" >&2
    exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP" "$TMP.valid"' EXIT

log "Загрузка ключей из $SRC ..."
case "$SRC" in
    http*) curl -fsSL "$SRC" > "$TMP" ;;
    *)     cat "$SRC" > "$TMP" ;;
esac

if grep -q 'PRIVATE KEY' "$TMP"; then
    echo "!! Это выглядит как приватный ключ. Нужен ПУБЛИЧНЫЙ (*.pub или .keys)." >&2
    exit 1
fi

# только строки валидного формата (ssh-ed25519/ecdsa/sk-*), мусор отбрасываем
grep -Ec '^([A-Za-z0-9@.-]+) [A-Za-z0-9+/]+=*( .*)?$' "$TMP" >/dev/null \
    && grep -E '^(sk-)?(ssh|ecdsa)-[A-Za-z0-9@.-]+ [A-Za-z0-9+/]+=*( .*)?$' "$TMP" > "$TMP.valid" \
    || { echo "!! Валидных публичных ключей не найдено" >&2; exit 1; }

install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# идемпотентно: добавляем только отсутствующие строки
added=0
while IFS= read -r line; do
    grep -qxF "$line" /root/.ssh/authorized_keys || { printf '%s\n' "$line" >> /root/.ssh/authorized_keys; added=$((added+1)); }
done < "$TMP.valid"

total="$(wc -l < /root/.ssh/authorized_keys)"
log "Добавлено новых ключей: $added, всего в authorized_keys: $total"

# Негативная проверка ДО hardening: пароли на сервере ещё включены (их отключит
# 30-hardening.sh), поэтому достаточно однократного `PubkeyAuthentication=no`.
# Отключаем остальные методы НА СТОРОНЕ КЛИЕНТА — иначе ssh честно спросит
# пароль, и проверка «зависнет» вместо мгновенного отказа.
cat <<'BANNER'

════════════════════════════════════════════════════════════════
  ⚠️  СТОП. ПРОВЕРЬТЕ ВХОД, прежде чем запускать 30-hardening.sh

  Откройте НОВОЕ окно терминала (эту сессию не закрывайте!) и:

  1) ssh root@<этот-сервер>
        → должен пустить молча, без запроса пароля

  Пароли пока работают — так и задумано, их отключит следующий скрипт.
  Чтобы убедиться, что ключа хватит и после их отключения, откажитесь
  от пароля на стороне КЛИЕНТА (сервер продолжит предлагать, но клиент
  не станет ни использовать его, ни спрашивать у вас):

  2) ssh -o PubkeyAuthentication=no -o PasswordAuthentication=no \
         -o KbdInteractiveAuthentication=no root@<этот-сервер>
        → мгновенно "Permission denied (publickey,password)" БЕЗ приглашения
          ввода пароля

  Оба пункта зелёные? Тогда запускайте:
        sudo ./30-hardening.sh
════════════════════════════════════════════════════════════════
BANNER