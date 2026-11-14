#!/bin/bash
# ssb-transport443-ticket — отправка конфигов заказа (gRPC/XHTTP на 443) в тикет.
#
#   ssb-transport443-ticket <номер тикета> [--with-ws] [--labels] [--dry-run] [--force]
#
# Что отправляет:
#   по умолчанию — только ссылки 443-транспортов (gRPC + XHTTP) из
#   /root/ssb-transport443-out/<ORDER>/links-by-user.txt (порядок: пользователь 1,
#   его 4 ссылки, пользователь 2, ...). Формат — чистые URL по одному в строке,
#   как в штатном sing_box_ticket.sh (чтобы сторона биллинга разобрала так же).
#
#   --with-ws — добавить к ним ws-ссылки из /root/all_configs_sing_box.txt (если есть)
#   --labels  — добавить заголовки-разделители (только для чтения человеком;
#               может помешать разбору URL на стороне биллинга — по умолчанию выкл.)
#   --dry-run — ничего не отправлять, показать полезную нагрузку и размер запроса
#   --force   — отправить даже если URL запроса длиннее 8000 символов
#   --order ORDER-xxxxxx — взять ссылки конкретного заказа (по умолчанию — последний)
#
# Тикет: аргумент либо /root/to_send.txt (его пишет штатный sing_box_ticket.sh).
# Заказ (orderid): hostname -s — как в штатном скрипте.
# URL API тикетов: переменная окружения SSB_TICKET_URL либо файл
# /etc/ssb-transport443.env (в публичный репозиторий не вшит).
set -uo pipefail

TICKET=""; WITH_WS=0; LABELS=0; DRY=0; FORCE=0; ORDER=""

# SSB_TICKET_DRY=1 — режим dry-run (для тестов и цепочек без реальной отправки)
[[ ${SSB_TICKET_DRY:-0} == 1 ]] && DRY=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-ws) WITH_WS=1 ;;
        --labels)  LABELS=1 ;;
        --dry-run) DRY=1 ;;
        --force)   FORCE=1 ;;
        --order)   ORDER="${2:-}"; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) [[ -z $TICKET ]] && TICKET="$1" || { echo "Лишний аргумент: $1" >&2; exit 1; } ;;
    esac
    shift
done

if [[ -z $TICKET && -f ${SSB_TICKET_FILE:-/root/to_send.txt} ]]; then
    TICKET=$(tr -d '[:space:]' < "${SSB_TICKET_FILE:-/root/to_send.txt}")
fi
if [[ -z $TICKET ]]; then
    read -r -p "Номер тикета: " TICKET
fi
[[ $TICKET =~ ^[0-9]+$ ]] || { echo "Ошибка: номер тикета должен быть числом (получено '$TICKET')" >&2; exit 1; }

OUTROOT=${SSB_T443_OUTROOT:-/root/ssb-transport443-out}
WS_LIST=${SSB_WS_LIST:-/root/all_configs_sing_box.txt}

if [[ -z $ORDER ]]; then
    ORDER=$(ls -1dt "$OUTROOT"/ORDER-*/ 2>/dev/null | head -n1)
    ORDER=${ORDER%/}; ORDER=${ORDER##*/}
fi
[[ $ORDER =~ ^ORDER-[0-9]+$ ]] || { echo "Ошибка: не найден каталог заказа в $OUTROOT (укажи --order ORDER-123456)" >&2; exit 1; }
BYUSER="$OUTROOT/$ORDER/links-by-user.txt"
[[ -f $BYUSER ]] || { echo "Ошибка: нет $BYUSER — сначала ssb-transport443-add" >&2; exit 1; }

# --- сборка полезной нагрузки ---
# только строки-ссылки, в порядке файла (пользователь за пользователем)
payload=$(: < /dev/null; grep -oE 'https?://[^[:space:]]+' "$BYUSER" || true)
if (( WITH_WS )) && [[ -f $WS_LIST ]]; then
    ws=$(grep -oE 'https?://[^[:space:]]+' "$WS_LIST" || true)
    if [[ -n $ws ]]; then
        if (( LABELS )); then
            payload=$(printf '=== 443 (gRPC / XHTTP) ===\n%s\n\n=== ws ===\n%s' "$payload" "$ws")
        else
            payload=$(printf '%s\n%s' "$payload" "$ws")
        fi
    fi
fi
[[ -n $payload ]] || { echo "Ошибка: нет ссылок для отправки" >&2; exit 1; }

count=$(printf '%s\n' "$payload" | grep -cE '^https?://' || true)

b64url() { base64 -w 0 | tr '/+' '_-' | tr -d '='; }
PASSENC=$(printf '%s' "${SSB_TICKET_PASS:-12345}" | b64url)
PAYLOADENC=$(printf '%s' "$payload" | b64url)

HOSTID=$(hostname -s)
# URL API тикетов задаётся снаружи (переменная окружения SSB_TICKET_URL или
# файл /etc/ssb-transport443.env с ней) — в публичный репозиторий он не вшит.
if [[ -z ${API:-} && -f /etc/ssb-transport443.env ]]; then
    # shellcheck disable=SC1091
    . /etc/ssb-transport443.env
fi
API="${SSB_TICKET_URL:-}"
if [[ -z $API ]]; then
    if (( DRY )); then
        API="https://billing.example.test/orderstask_2.php"
    else
        echo "Ошибка: не задан URL API тикетов." >&2
        echo "  SSB_TICKET_URL='<url биллинга>' ssb-transport443-ticket $TICKET" >&2
        echo "  либо прописать SSB_TICKET_URL=... в /etc/ssb-transport443.env" >&2
        exit 1
    fi
fi
URL="$API?installtype=sing_box_t_install&orderid=${HOSTID}&ticketid=${TICKET}&dataparamone=${PAYLOADENC}&dataparamtwo=${PASSENC}"

echo "заказ      : $ORDER (orderid=${HOSTID})"
echo "тикет      : $TICKET"
echo "ссылок     : ${count} (ws: $(( WITH_WS ? 1 : 0 )))"
echo "длина URL  : ${#URL} символов"

if (( ${#URL} > 8000 )) && (( ! FORCE )); then
    echo
    echo "!! URL длиннее 8000 символов — веб-сервер биллинга может отклонить запрос (414)." >&2
    echo "   Варианты: --schemes grpc|xhttp (меньше ссылок), меньше --count," >&2
    echo "   либо отправить ws отдельно (штатным скриптом), а тут — только 443." >&2
    echo "   Отправить всё равно: --force" >&2
    exit 1
fi

if (( DRY )); then
    echo
    echo "--- payload (--dry-run, не отправлено) ---"
    printf '%s\n' "$payload"
    exit 0
fi

printf '%s\n' "$payload" > "$OUTROOT/$ORDER/ticket-payload.txt"
chmod 600 "$OUTROOT/$ORDER/ticket-payload.txt"

resp=$(curl -k -sS --max-time 60 "$URL")
echo "ответ      : ${resp:-<пусто>}"
echo "$(date '+%F %T') order=${ORDER} ticket=${TICKET} links=${count} ticket-send" >> /root/ssb-orders.log
