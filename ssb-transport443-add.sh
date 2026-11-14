#!/bin/bash
# ssb-transport443-add — выдать конфиги заказа: VLESS + Trojan по gRPC и XHTTP на 443.
#
# Использование:
#   ssb-transport443-add ORDER-xxxxxx [count=10] [out-tag] [name=<база>]
#   SCHEMES=grpc|both|xhttp ssb-transport443-add ORDER-xxxxxx 10 out-123456
#
# По умолчанию: count x 4 файла (TRJ+VLESS) x (gRPC+XHTTP) = count x 2 x 2.
#   SCHEMES=grpc  -> только gRPC   (count x 2 файла)
#   SCHEMES=xhttp -> только XHTTP  (count x 2 файла)
# Маршрут в конфигах — как в проде (32 rule_set, resolve -> geoip-ru -> direct,
# reject последним), выход — ТОЛЬКО персональный OUT заказа.
set -uo pipefail

ORDER="${1:-}"; COUNT="${2:-10}"; OUT="${3:-}"; NAMEARG="${4:-}"
SCHEMES="${SCHEMES:-both}"

usage() {
    cat <<EOF
Использование: ssb-transport443-add ORDER-xxxxxx [count=10] [out-tag] [name=<база>]
  SCHEMES=both|grpc|xhttp (по умолчанию both)
Пример: ssb-transport443-add ORDER-123456 10 out-123456
EOF
    exit 1
}

[[ $ORDER =~ ^ORDER-[0-9]+$ ]] || usage
[[ $COUNT =~ ^[0-9]+$ ]] && (( COUNT >= 1 && COUNT <= 50 )) || { echo "Ошибка: count = 1..50"; exit 1; }
case "$SCHEMES" in both|grpc|xhttp) ;; *) echo "Ошибка: SCHEMES = both|grpc|xhttp"; exit 1 ;; esac

SBCFG=${SBCFG:-/etc/sing-box/config.json}
NGINX=${NGINX:-/etc/nginx/nginx.conf}
TPL=${TPL:-/usr/local/share/ssb-transport443/tpl.json}
[[ -f $SBCFG ]] || { echo "Ошибка: SSB не установлен ($SBCFG)"; exit 1; }
[[ -f $TPL ]] || { echo "Ошибка: нет шаблона $TPL (запустите install.sh)"; exit 1; }

IN_TRJ_GRPC=trj-grpc-443
IN_VLESS_GRPC=vless-grpc-443
IN_TRJ_XHTTP=trj-xhttp-443
IN_VLESS_XHTTP=vless-xhttp-443

for t in "$IN_TRJ_GRPC" "$IN_VLESS_GRPC" "$IN_TRJ_XHTTP" "$IN_VLESS_XHTTP"; do
    jq -e --arg t "$t" 'any(.inbounds[]?; .tag == $t)' "$SBCFG" >/dev/null 2>&1 || {
        echo "Ошибка: inbound '$t' не найден. Сначала: ssb-transport443-patch apply"; exit 1; }
done

domain=$(grep -o 'ssl_certificate[[:space:]]*/etc/letsencrypt/live/[^/]*/' "$NGINX" 2>/dev/null | head -n1 | sed 's|.*/live/||; s|/$||')
[[ -n $domain ]] || domain=$(jq -r '[.inbounds[]?|select(.tls.enabled==true)|.tls.server_name]|map(select(.!=null and .!=""))|.[0]//""' "$SBCFG")
[[ -n $domain ]] || { echo "Ошибка: не удалось определить домен ноды"; exit 1; }

[[ -z $OUT ]] && OUT="out-${ORDER#ORDER-}"
jq -e --arg t "$OUT" 'any(.outbounds[]?; .tag == $t)' "$SBCFG" >/dev/null 2>&1 || {
    echo "Ошибка: OUT-узел '${OUT}' не найден. Политика: каждому заказу — персональный OUT."; exit 1; }

rand() { head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c12; }
backup_config() {
    cp "$SBCFG" "/root/sb-config-backup-$(date +%Y%m%d-%H%M%S).json"
    ls -1t /root/sb-config-backup-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
}

subspath=$(grep "location ~ ^/" "$NGINX" 2>/dev/null | tail -n 1 | cut -d "/" -f 2 | cut -d " " -f 1)
webdir=""; [[ -n $subspath && -d /var/www/$subspath ]] && webdir="/var/www/$subspath"
rulesetpath=$(grep "alias /var/www/" "$NGINX" 2>/dev/null | head -n 1 | cut -d "/" -f 4)

# --- шаблон клиента: prod-маршрутизация; каждый rule-set проверяется по факту ---
# Правило: набор используется, если файл реально есть на ноде (быстрый локальный
# URL), иначе — публичный GitHub-источник, если он отвечает 200. Наборы, которых
# нет ни там, ни там, выбрасываются вместе с ссылающимися на них правилами route/dns
# (иначе sing-box не стартует: "initial rule-set: <tag>: unexpected status: 404").
CTPL="/tmp/t443-tpl-$$.json"

# IP ноды: пиннится в правиле ip_cidr (защита от DNS-спуфинга домена ноды)
nodeip=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')
[[ -z $nodeip ]] && nodeip=$(dig +short A "$domain" 2>/dev/null | head -n1)
[[ -z $nodeip ]] && echo "ВНИМАНИЕ: не удалось определить IP домена ${domain} — пиннинг ip_cidr отключён"

python3 - "$TPL" "$CTPL" "$domain" "$rulesetpath" "$nodeip" <<'PY'
import json, os, subprocess, sys

src, dst, domain, rulesetpath, nodeip = sys.argv[1:6]
c = json.load(open(src))

# пиннинг IP ноды (плейсхолдер NODEIP в шаблоне)
for rule in c.get("route", {}).get("rules", []):
    if "NODEIP" not in rule.get("ip_cidr", []):
        continue
    if nodeip:
        rule["ip_cidr"] = [nodeip if x == "NODEIP" else x for x in rule["ip_cidr"]]
    else:
        rule["ip_cidr"] = [x for x in rule["ip_cidr"] if x != "NODEIP"]
        if not rule["ip_cidr"]:
            rule.pop("ip_cidr")

# наборы, которые лежат в A-Zuro/sb-rule-sets (формат source)
GH_SOURCE = {"torrent-clients", "bypass-apps", "encrypted-dns", "android-fcm"}

def gh_url(tag, filename):
    if tag in GH_SOURCE:
        return "https://raw.githubusercontent.com/A-Zuro/sb-rule-sets/main/" + filename
    if tag == "geoip-ru":
        return "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"
    return "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/" + filename

def reachable(url):
    try:
        r = subprocess.run(
            ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}", "-m", "8", url],
            capture_output=True, text=True, timeout=15)
        return r.stdout.strip() == "200"
    except Exception:
        return False

local_dir = os.path.join("/var/www", rulesetpath) if rulesetpath else ""
keep, dropped = [], []

for rs in c.get("route", {}).get("rule_set", []):
    tag = rs["tag"]
    filename = rs["url"].rsplit("/", 1)[-1]
    if local_dir and os.path.isfile(os.path.join(local_dir, filename)):
        rs["url"] = "https://%s/%s/%s" % (domain, rulesetpath, filename)
        keep.append(rs)
        continue
    url = gh_url(tag, filename)
    if reachable(url):
        rs["url"] = url
        keep.append(rs)
    else:
        dropped.append(tag)

c["route"]["rule_set"] = keep
available = {rs["tag"] for rs in keep}

# вычистить правила, ссылающиеся на выброшенные наборы
pruned = 0
for section in ("route", "dns"):
    rules = c.get(section, {}).get("rules")
    if not isinstance(rules, list):
        continue
    new_rules = []
    for rule in rules:
        if "rule_set" in rule:
            filtered = [t for t in rule["rule_set"] if t in available]
            if not filtered:
                pruned += 1
                continue
            rule["rule_set"] = filtered
        new_rules.append(rule)
    c[section]["rules"] = new_rules

json.dump(c, open(dst, "w"), ensure_ascii=False, indent=1)

if dropped:
    sys.stderr.write("ВНИМАНИЕ: нет rule-set (%d): %s — правила с ними удалены (%d)\n"
                     % (len(dropped), ", ".join(dropped), pruned))
print("rule-set: %d из %d (локально/с GitHub), правил route=%d dns=%d"
      % (len(keep), len(keep) + len(dropped),
         len(c["route"].get("rules", [])), len(c.get("dns", {}).get("rules", []))))
PY

# подставить домен в dns/outbound/domain_suffix (остальные 36 вхождений DOMAIN)
python3 - "$CTPL" "$domain" <<'PY'
import sys
path, domain = sys.argv[1:3]
text = open(path).read()
if "DOMAIN" in text:
    open(path, "w").write(text.replace("DOMAIN", domain))
PY

grep -q "NODEIP" "$CTPL" && { echo "Ошибка: в шаблоне остался плейсхолдер NODEIP"; exit 1; }

gen_cfg() { # $1=файл, $2=proxy-outbound json
    jq --argjson proxy "$2" '(.outbounds[] | select(.tag=="proxy")) = $proxy' "$CTPL" > "$1"
    chmod 644 "$1"
}

OUTDIR="/root/ssb-transport443-out/${ORDER}"
mkdir -p "$OUTDIR"; chmod 700 /root/ssb-transport443-out "$OUTDIR" 2>/dev/null

echo "Заказ ${ORDER}: ${COUNT} конфигов x (TRJ+VLESS) x (${SCHEMES}), домен ${domain}, OUT '${OUT}'"
backup_config

names=(); add_tj=""; add_vl=""
links_grpc=""; links_xhttp=""
for ((i = 1; i <= COUNT; i++)); do
    if [[ -n $NAMEARG ]]; then
        base="${NAMEARG#name=}"
        base="${base#name=}"
        [[ $base =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { echo "Ошибка: name = латиница/цифры/_/-, до 32 символов"; exit 1; }
        name="${ORDER}-${base}$( ((COUNT > 1)) && echo "-$i")"
    else
        name="${ORDER}-$(rand)"
    fi
    trjpass="$(rand)"; uuid=$(cat /proc/sys/kernel/random/uuid)
    names+=("$name")
    add_tj+="${add_tj:+,}{\"name\":\"${name}\",\"password\":\"${trjpass}\"}"
    add_vl+="${add_vl:+,}{\"name\":\"${name}\",\"uuid\":\"${uuid}\"}"

    if [[ $SCHEMES == both || $SCHEMES == grpc ]]; then
        P_TRJ_G=$(jq -n --arg d "$domain" --arg pw "$trjpass" '
            {type:"trojan", tag:"proxy", server:$d, server_port:443, password:$pw,
             tls:{enabled:true, server_name:$d, alpn:["h2"]},
             transport:{type:"grpc", service_name:"trj"}}')
        P_VL_G=$(jq -n --arg d "$domain" --arg u "$uuid" '
            {type:"vless", tag:"proxy", server:$d, server_port:443, uuid:$u,
             tls:{enabled:true, server_name:$d, alpn:["h2"]},
             transport:{type:"grpc", service_name:"vless"}}')
        gen_cfg "${OUTDIR}/${name}-TRJ-GRPC-CLIENT.json" "$P_TRJ_G"
        gen_cfg "${OUTDIR}/${name}-VLESS-GRPC-CLIENT.json" "$P_VL_G"
        links_grpc+="${name}-TRJ-GRPC-CLIENT.json"$'\n'"${name}-VLESS-GRPC-CLIENT.json"$'\n'
    fi
    if [[ $SCHEMES == both || $SCHEMES == xhttp ]]; then
        P_TRJ_X=$(jq -n --arg d "$domain" --arg pw "$trjpass" '
            {type:"trojan", tag:"proxy", server:$d, server_port:443, password:$pw,
             tls:{enabled:true, server_name:$d, alpn:["h2"]},
             transport:{type:"http", host:[$d], path:"/trj-xhttp"}}')
        P_VL_X=$(jq -n --arg d "$domain" --arg u "$uuid" '
            {type:"vless", tag:"proxy", server:$d, server_port:443, uuid:$u,
             tls:{enabled:true, server_name:$d, alpn:["h2"]},
             transport:{type:"http", host:[$d], path:"/vless-xhttp"}}')
        gen_cfg "${OUTDIR}/${name}-TRJ-XHTTP-CLIENT.json" "$P_TRJ_X"
        gen_cfg "${OUTDIR}/${name}-VLESS-XHTTP-CLIENT.json" "$P_VL_X"
        links_xhttp+="${name}-TRJ-XHTTP-CLIENT.json"$'\n'"${name}-VLESS-XHTTP-CLIENT.json"$'\n'
    fi
done

# users в loopback-инбаунды
jq --argjson u "[${add_tj}]" '(.inbounds[] | select(.tag=="'"$IN_TRJ_GRPC"'" or .tag=="'"$IN_TRJ_XHTTP"'") | .users) += $u' "$SBCFG" > /tmp/t443.$$.json && mv /tmp/t443.$$.json "$SBCFG"
jq --argjson u "[${add_vl}]" '(.inbounds[] | select(.tag=="'"$IN_VLESS_GRPC"'" or .tag=="'"$IN_VLESS_XHTTP"'") | .users) += $u' "$SBCFG" > /tmp/t443.$$.json && mv /tmp/t443.$$.json "$SBCFG"

# маршрут -> персональный OUT (правило ставится перед reject)
names_json=$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)
if jq -e --arg t "$OUT" 'any(.route.rules[]?; .outbound == $t and has("auth_user"))' "$SBCFG" >/dev/null 2>&1; then
    jq --arg t "$OUT" --argjson n "$names_json" '(.route.rules[] | select(.outbound == $t and has("auth_user")) | .auth_user) += $n' \
        "$SBCFG" > /tmp/t443.$$.json && mv /tmp/t443.$$.json "$SBCFG"
else
    jq --arg t "$OUT" --argjson n "$names_json" '
        .route.rules = ((.route.rules | map(select(.action != "reject"))) + [{"auth_user": $n, "outbound": $t}] + [{"action":"reject"}])' \
        "$SBCFG" > /tmp/t443.$$.json && mv /tmp/t443.$$.json "$SBCFG"
fi

rm -f "$CTPL"
if sing-box check -C "$(dirname "$SBCFG")" >/dev/null 2>&1; then
    systemctl reload sing-box.service 2>/dev/null; sleep 5
    systemctl is-active --quiet sing-box.service 2>/dev/null || { systemctl restart sing-box.service; sleep 8; }
    systemctl is-active --quiet sing-box.service || { echo "!!! sing-box не активен"; exit 1; }
else
    echo "!!! sing-box check провалился — откат"
    cp "$(ls -1t /root/sb-config-backup-*.json | head -1)" "$SBCFG"
    exit 1
fi

# выкладка в веб-каталог (ссылки для клиента/тикета)
base=""
if [[ -n $webdir ]]; then
    cp "$OUTDIR"/*-CLIENT.json "$webdir"/ && chmod 644 "$webdir"/*-CLIENT.json
    base="https://${domain}/${subspath}"
else
    base="$OUTDIR"
fi

mk_links() { # $1 = список файлов построчно
    local f
    while IFS= read -r f; do
        [[ -n $f ]] && printf '%s/%s\n' "$base" "$f"
    done <<< "$1"
}

lv_grpc=$(mk_links "$links_grpc")
lv_xhttp=$(mk_links "$links_xhttp")
printf '%s\n%s\n' "$lv_grpc" "$lv_xhttp" | sed '/^$/d' > "${OUTDIR}/links-all.txt"
chmod 600 "${OUTDIR}/links-all.txt"

# --- выдача по пользователям: один блок = один клиент (все его транспорты) ---
by_user=""
n=0
for name in "${names[@]}"; do
    n=$((n + 1))
    by_user+="Пользователь ${n} — ${name}"$'\n'
    for kind in TRJ-GRPC VLESS-GRPC TRJ-XHTTP VLESS-XHTTP; do
        f="${name}-${kind}-CLIENT.json"
        [[ -f "${OUTDIR}/${f}" ]] && by_user+="$(printf '  %-11s ' "$kind")${base}/${f}"$'\n'
    done
    by_user+=$'\n'
done
printf '%s' "$by_user" > "${OUTDIR}/links-by-user.txt"
chmod 600 "${OUTDIR}/links-by-user.txt"

echo "$(date '+%F %T') order=${ORDER} transport443-add count=${COUNT} schemes=${SCHEMES} out=${OUT}" >> /root/ssb-orders.log

if [[ -n $lv_grpc || -n $lv_xhttp ]]; then echo; printf '%s' "$by_user"; fi
echo
echo "=== Итого: $(wc -l < "${OUTDIR}/links-all.txt" | tr -d ' ') файлов; маршрут: ${ORDER} -> ${OUT} ==="
echo "Файлы: ${OUTDIR}/"
echo "  links-by-user.txt — ссылки по пользователям (для выдачи клиенту)"
echo "  links-all.txt     — плоский список (для тикета)"
