#!/bin/bash
# install.sh — установка ssb-transport443 (gRPC и XHTTP на 443) на ноду SSB.
#
# Минимум (только поставить скрипты):
#   curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh | bash
#
# Всё одной командой (поставить + включить на 443 + выдать конфиги заказа):
#   curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh \
#     | bash -s -- --apply --order ORDER-123456 --count 10 --out out-123456
#
# Ставит:
#   /usr/local/bin/ssb-transport443-patch      (apply | remove | status)
#   /usr/local/bin/ssb-transport443-add        (выдача конфигов заказа)
#   /usr/local/bin/ssb-transport443-ticket     (отправка 443-ссылок в тикет)
#   /usr/local/share/ssb-transport443/tpl.json (шаблон клиента: прод-маршрутизация)
#
# Флаги (все необязательные):
#   --apply                 сразу включить gRPC+XHTTP на 443 (patch apply)
#   --order ORDER-123456    сразу выдать конфиги заказа (auto = номер из hostname)
#   --count N               число конфигов, 1..50 (по умолчанию 10)
#   --out out-123456        персональный OUT (по умолчанию out-<номер заказа>)
#   --schemes both|grpc|xhttp   какие транспорты выдавать (по умолчанию both)
#   --name <база>           база имени конфигов (латиница/цифры/_/-, до 32)
#   --ticket N              отправить конфиги в тикет N (после выдачи; auto = из /root/to_send.txt)
#   --with-ws               в тикет добавить и ws-ссылки (по умолчанию только 443)
#   --status                показать состояние после установки
#   -h | --help             эта справка
set -euo pipefail

RAW="${SSB_T443_RAW:-https://raw.githubusercontent.com/Anton98567/ssb-transport443/main}"
BIN="${SSB_T443_BIN:-/usr/local/bin}"
SHARE="${SSB_T443_SHARE:-/usr/local/share/ssb-transport443}"

APPLY=0; STATUS=0; ORDER=""; COUNT=""; OUT=""; SCHEMES=""; NAME=""; TICKET=""; WITH_WS=0

usage() {
    cat <<'EOF'
ssb-transport443 — gRPC и XHTTP на 443 для ноды SSB.

  curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh \
    | bash -s -- --apply --order ORDER-123456 --count 10 --out out-123456

Флаги (все необязательные):
  --apply                 сразу включить gRPC+XHTTP на 443 (patch apply)
  --order ORDER-123456    сразу выдать конфиги заказа (auto = номер из hostname)
  --count N               число конфигов, 1..50 (по умолчанию 10)
  --out out-123456        персональный OUT (по умолчанию out-<номер заказа>)
  --schemes both|grpc|xhttp   какие транспорты выдавать (по умолчанию both)
  --name <база>           база имени конфигов (латиница/цифры/_/-, до 32)
  --ticket N              отправить конфиги в тикет N (после выдачи; auto = из /root/to_send.txt)
  --with-ws               в тикет добавить и ws-ссылки (по умолчанию только 443)
  --status                показать состояние после установки
  -h | --help             эта справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)   APPLY=1 ;;
        --status)  STATUS=1 ;;
        --order)   ORDER="${2:-}"; shift ;;
        --count)   COUNT="${2:-}"; shift ;;
        --out)     OUT="${2:-}"; shift ;;
        --schemes) SCHEMES="${2:-}"; shift ;;
        --name)    NAME="${2:-}"; shift ;;
        --ticket)  TICKET="${2:-}"; shift ;;
        --with-ws) WITH_WS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестный аргумент: $1 (см. --help)" >&2; exit 1 ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || { echo "нужен root" >&2; exit 1; }

SCHEMES="${SCHEMES:-both}"
case "$SCHEMES" in both|grpc|xhttp) ;; *) echo "Ошибка: --schemes both|grpc|xhttp" >&2; exit 1 ;; esac
# --order auto  -> ORDER-<номер из hostname> (у SSB-нод hostname = номер заказа, напр. 137072)
if [[ $ORDER == auto ]]; then
    h=$(hostname -s 2>/dev/null | grep -oE '^[0-9]+' || true)
    [[ -n $h ]] || { echo "Ошибка: --order auto — в hostname нет номера, укажи --order ORDER-123456" >&2; exit 1; }
    ORDER="ORDER-$h"
fi
# --order 123456 -> ORDER-123456
[[ -n $ORDER && $ORDER =~ ^[0-9]+$ ]] && ORDER="ORDER-$ORDER"
if [[ -n $ORDER && ! $ORDER =~ ^ORDER-[0-9]+$ ]]; then
    echo "Ошибка: заказ в формате ORDER-<цифры> (например ORDER-123456)" >&2; exit 1
fi

# если запускаем из каталога репозитория — берём файлы локально
SRC=""
if [[ -f ./ssb-transport443-patch.sh && -f ./ssb-transport443-add.sh && -f ./tpl.json ]]; then
    SRC="$PWD"
fi

mkdir -p "$BIN" "$SHARE"

fetch() { # $1 = имя файла, $2 = куда
    if [[ -n $SRC ]]; then
        cp "$SRC/$1" "$2"
    else
        curl -fsSL "$RAW/$1" -o "$2"
    fi
}

fetch ssb-transport443-patch.sh "$BIN/ssb-transport443-patch"
fetch ssb-transport443-add.sh "$BIN/ssb-transport443-add"
fetch ssb-transport443-ticket.sh "$BIN/ssb-transport443-ticket"
fetch tpl.json "$SHARE/tpl.json"

chmod 755 "$BIN/ssb-transport443-patch" "$BIN/ssb-transport443-add" "$BIN/ssb-transport443-ticket"
chmod 644 "$SHARE/tpl.json"

echo "Установлено:"
echo "  $BIN/ssb-transport443-patch"
echo "  $BIN/ssb-transport443-add"
echo "  $BIN/ssb-transport443-ticket"
echo "  $SHARE/tpl.json"

if (( APPLY )); then
    echo
    echo "== включаю gRPC+XHTTP на 443 =="
    "$BIN/ssb-transport443-patch" apply
fi

if [[ -n $ORDER ]]; then
    echo
    echo "== выдаю конфиги заказа =="
    COUNT="${COUNT:-10}"
    # по умолчанию — персональный OUT с именем out-<номер заказа>
    OUT="${OUT:-out-${ORDER#ORDER-}}"
    args=("$ORDER" "$COUNT" "$OUT")
    [[ -n $NAME ]] && args+=("name=$NAME")
    SCHEMES="${SCHEMES:-both}" "$BIN/ssb-transport443-add" "${args[@]}"
fi

if [[ -n $TICKET ]]; then
    outroot="${SSB_T443_OUTROOT:-/root/ssb-transport443-out}"
    if [[ -z $ORDER && ! -d $outroot ]]; then
        echo "Ошибка: --ticket без --order и без ранее выданных конфигов" >&2
        exit 1
    fi
    if [[ $TICKET == auto ]]; then
        to_send="${SSB_TICKET_FILE:-/root/to_send.txt}"
        [[ -f $to_send ]] || { echo "Ошибка: --ticket auto — нет $to_send (номер тикета пишет sing_box_ticket.sh)" >&2; exit 1; }
        TICKET=$(tr -d '[:space:]' < "$to_send")
    fi
    echo
    echo "== отправляю конфиги в тикет $TICKET =="
    targs=("$TICKET")
    [[ $WITH_WS -eq 1 ]] && targs+=("--with-ws")
    [[ -n $ORDER ]] && targs+=("--order" "$ORDER")
    "$BIN/ssb-transport443-ticket" "${targs[@]}"
fi

if (( STATUS )); then
    echo
    "$BIN/ssb-transport443-patch" status
fi

if (( ! APPLY )) && [[ -z $ORDER && -z $TICKET ]]; then
    echo
    echo "Дальше:"
    echo "  1) ssb-transport443-patch apply        # gRPC+XHTTP на 443"
    echo "  2) ssb-transport443-add ORDER-123456 10 out-123456"
    echo "  3) ssb-transport443-ticket <номер тикета>"
    echo "  либо всё сразу:  ... install.sh | bash -s -- --apply --order auto --ticket auto"
fi
