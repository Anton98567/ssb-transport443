#!/bin/bash
# install.sh — установка ssb-transport443 (gRPC и XHTTP на 443) на ноду SSB.
#
#   curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh | bash
#
# Ставит:
#   /usr/local/bin/ssb-transport443-patch     (apply | remove | status)
#   /usr/local/bin/ssb-transport443-add       (выдача конфигов заказа)
#   /usr/local/share/ssb-transport443/tpl.json (шаблон клиента: прод-маршрутизация)
set -euo pipefail

RAW="https://raw.githubusercontent.com/Anton98567/ssb-transport443/main"
BIN=/usr/local/bin
SHARE=/usr/local/share/ssb-transport443

[[ $EUID -eq 0 ]] || { echo "нужен root" >&2; exit 1; }

# если запускаем из каталога репозитория — берём файлы локально
SRC=""
if [[ -f ./ssb-transport443-patch.sh && -f ./ssb-transport443-add.sh && -f ./tpl.json ]]; then
    SRC="$PWD"
fi

mkdir -p "$SHARE"

fetch() { # $1 = имя файла, $2 = куда
    if [[ -n $SRC ]]; then
        cp "$SRC/$1" "$2"
    else
        curl -fsSL "$RAW/$1" -o "$2"
    fi
}

fetch ssb-transport443-patch.sh "$BIN/ssb-transport443-patch"
fetch ssb-transport443-add.sh "$BIN/ssb-transport443-add"
fetch tpl.json "$SHARE/tpl.json"

chmod 755 "$BIN/ssb-transport443-patch" "$BIN/ssb-transport443-add"
chmod 644 "$SHARE/tpl.json"

echo "Установлено:"
echo "  $BIN/ssb-transport443-patch"
echo "  $BIN/ssb-transport443-add"
echo "  $SHARE/tpl.json"
echo
echo "Дальше:"
echo "  1) ssb-transport443-patch apply        # gRPC+XHTTP на 443"
echo "  2) ssb-transport443-add ORDER-123456 10 out-123456"
