#!/bin/bash
# ssb-transport443-patch — gRPC и XHTTP на 443 через nginx на ноде SSB.
#
# Схема: TLS терминирует nginx на 443, дальше по путям grpc_pass (h2c) в
# loopback-инбаунды sing-box:
#   /trj/        -> trojan + gRPC   (service_name trj)    127.0.0.1:20443
#   /vless/      -> vless  + gRPC   (service_name vless)  127.0.0.1:20444
#   /trj-xhttp   -> trojan + HTTP/2 (path /trj-xhttp)     127.0.0.1:20445
#   /vless-xhttp -> vless  + HTTP/2 (path /vless-xhttp)   127.0.0.1:20446
#
# Использование:
#   ssb-transport443-patch apply     # включить (идемпотентно)
#   ssb-transport443-patch remove    # полностью откатить
#   ssb-transport443-patch status    # состояние + проба
set -uo pipefail

SBCFG=${SBCFG:-/etc/sing-box/config.json}
NGINX=${NGINX:-/etc/nginx/nginx.conf}
SBIN=/etc/sing-box

P_TRJ_GRPC=20443
P_VLESS_GRPC=20444
P_TRJ_XHTTP=20445
P_VLESS_XHTTP=20446

T_TRJ_GRPC=trj-grpc-443
T_VLESS_GRPC=vless-grpc-443
T_TRJ_XHTTP=trj-xhttp-443
T_VLESS_XHTTP=vless-xhttp-443

MARK_START="# >>> ssb-transport443"
MARK_END="# <<< ssb-transport443"

die() { echo "Ошибка: $*" >&2; exit 1; }
say() { echo "$*"; }

[[ $EUID -eq 0 ]] || die "нужен root"
[[ -f $SBCFG ]] || die "нет $SBCFG — SSB не установлен"
[[ -f $NGINX ]] || die "нет $NGINX"

domain() {
    local d=""
    d=$(jq -r '[.inbounds[] | select(.tls.enabled == true) | .tls.server_name] | map(select(. != null and . != "")) | .[0] // ""' "$SBCFG" 2>/dev/null)
    if [[ -z $d ]]; then
        d=$(grep -o 'ssl_certificate[[:space:]]*/etc/letsencrypt/live/[^/]*/' "$NGINX" 2>/dev/null | head -n1 | sed 's|.*/live/||; s|/$||')
    fi
    if [[ -z $d && -f /etc/ssb-node.conf ]]; then
        d=$(grep -E '^SSB_DOMAIN=' /etc/ssb-node.conf | cut -d= -f2- | tr -d '"'"'"' ')
    fi
    printf '%s' "$d"
}

backup() {
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp "$SBCFG" "/root/sb-config-backup-$ts.json"
    cp "$NGINX" "/root/nginx.conf.bak-$ts"
    ls -1t /root/sb-config-backup-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
    ls -1t /root/nginx.conf.bak-* 2>/dev/null | tail -n +11 | xargs -r rm -f
    say "бэкап: /root/sb-config-backup-$ts.json, /root/nginx.conf.bak-$ts"
}

rand() { head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c12; }

nginx_insert() {
    local d="$1"
    python3 - "$NGINX" "$d" "$MARK_START" "$MARK_END" \
        "$P_TRJ_GRPC" "$P_VLESS_GRPC" "$P_TRJ_XHTTP" "$P_VLESS_XHTTP" <<'PY'
import re, sys
path, domain, ms, me, p_tg, p_vg, p_tx, p_vx = sys.argv[1:9]
s = open(path).read()
if ms in s:
    print("nginx: блок ssb-transport443 уже есть")
    sys.exit(0)

block = f"""{ms}
        # gRPC + XHTTP на 443 (TLS терминирует nginx, апстрим — h2c в sing-box)
        location /trj/ {{
            grpc_pass grpc://127.0.0.1:{p_tg};
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
            grpc_socket_keepalive on;
        }}
        location = /trj {{
            grpc_pass grpc://127.0.0.1:{p_tg};
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
        }}
        location /vless/ {{
            grpc_pass grpc://127.0.0.1:{p_vg};
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
            grpc_socket_keepalive on;
        }}
        location = /vless {{
            grpc_pass grpc://127.0.0.1:{p_vg};
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
        }}
        location /trj-xhttp {{
            grpc_pass grpc://127.0.0.1:{p_tx};
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
            grpc_socket_keepalive on;
        }}
        location /vless-xhttp {{
            grpc_pass grpc://127.0.0.1:{p_vx};
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
            grpc_socket_keepalive on;
        }}
{me}
"""

lines = s.split("\n")
anchor = None
for i, ln in enumerate(lines):
    if re.match(r"\s*location\s+@ws_proxy\s*\{", ln):
        anchor = i
        break
if anchor is None:
    for i, ln in enumerate(lines):
        if re.match(r"\s*#\s*Reverse proxy\s*$", ln):
            anchor = i
            break
if anchor is None:
    for i, ln in enumerate(lines):
        if re.match(r"\s*location\s+/\s*\{\s*$", ln):
            anchor = i
            break
if anchor is None:
    sys.exit("nginx: не найден якорь для вставки (нужен location @ws_proxy или location /)")

lines.insert(anchor, block)
open(path, "w").write("\n".join(lines))
print("nginx: блок ssb-transport443 добавлен перед строкой", anchor + 1)
PY
}

nginx_remove() {
    python3 - "$NGINX" "$MARK_START" "$MARK_END" <<'PY'
import sys
path, ms, me = sys.argv[1:4]
lines = open(path).read().split("\n")
try:
    a = lines.index(ms.strip())
    b = lines.index(me.strip())
except ValueError:
    print("nginx: блока ssb-transport443 нет")
    sys.exit(0)
del lines[a:b + 1]
open(path, "w").write("\n".join(lines))
print("nginx: блок ssb-transport443 удалён")
PY
}

add_inbounds() {
    local seed_u seed_p seed_id
    seed_u="seed-$(rand)"; seed_p="$(rand)$(rand)"; seed_id=$(cat /proc/sys/kernel/random/uuid)
    jq --arg u "$seed_u" --arg p "$seed_p" --arg id "$seed_id" \
       --arg t1 "$T_TRJ_GRPC" --arg t2 "$T_VLESS_GRPC" --arg t3 "$T_TRJ_XHTTP" --arg t4 "$T_VLESS_XHTTP" \
       --argjson p1 "$P_TRJ_GRPC" --argjson p2 "$P_VLESS_GRPC" --argjson p3 "$P_TRJ_XHTTP" --argjson p4 "$P_VLESS_XHTTP" '
      .inbounds = ((.inbounds // []) | map(select((.tag // "") | test("-443$") | not)))
      | .inbounds += [
          {type:"trojan", tag:$t1, listen:"127.0.0.1", listen_port:$p1,
           users:[{name:$u, password:$p}],
           transport:{type:"grpc", service_name:"trj"}},
          {type:"vless", tag:$t2, listen:"127.0.0.1", listen_port:$p2,
           users:[{name:$u, uuid:$id}],
           transport:{type:"grpc", service_name:"vless"}},
          {type:"trojan", tag:$t3, listen:"127.0.0.1", listen_port:$p3,
           users:[{name:$u, password:$p}],
           transport:{type:"http", path:"/trj-xhttp"}},
          {type:"vless", tag:$t4, listen:"127.0.0.1", listen_port:$p4,
           users:[{name:$u, uuid:$id}],
           transport:{type:"http", path:"/vless-xhttp"}}
        ]' "$SBCFG" > /tmp/t443.$$.json || return 1
    mv /tmp/t443.$$.json "$SBCFG"
}

remove_inbounds() {
    jq 'if has("inbounds") then .inbounds |= map(select((.tag // "") | test("-443$") | not)) else . end' \
        "$SBCFG" > /tmp/t443.$$.json || return 1
    mv /tmp/t443.$$.json "$SBCFG"
}

reload_sb() {
    if sing-box check -C "$SBIN" >/dev/null 2>&1; then
        systemctl reload sing-box.service 2>/dev/null || systemctl restart sing-box.service
        sleep 4
        if ! systemctl is-active --quiet sing-box.service; then
            systemctl restart sing-box.service; sleep 6
        fi
        systemctl is-active --quiet sing-box.service
    else
        return 1
    fi
}

probe() {
    local d; d=$(domain)
    [[ -n $d ]] || { say "проба: домен не определён"; return 1; }
    local ok=0
    for p in /trj-xhttp /vless-xhttp; do
        local code
        code=$(curl -sk --http2 -m 6 -X PUT --resolve "$d:443:127.0.0.1" "https://$d$p" -o /dev/null -w '%{http_code}' 2>/dev/null)
        say "  PUT https://$d$p -> $code"
        [[ $code == 200 ]] && ok=$((ok+1))
    done
    for p in /trj/Tun /vless/Tun; do
        local code
        code=$(curl -sk --http2 -m 6 -X POST -H 'content-type: application/grpc' \
               --resolve "$d:443:127.0.0.1" "https://$d$p" -o /dev/null -w '%{http_code}' 2>/dev/null)
        say "  POST https://$d$p -> $code"
        [[ $code == 200 || $code == 000 ]] && ok=$((ok+1))
    done
    (( ok >= 3 ))
}

case "${1:-status}" in
apply)
    say "== ssb-transport443: apply (домен: $(domain))"
    backup
    add_inbounds || { say "!! не удалось обновить конфиг"; exit 1; }
    if ! sing-box check -C "$SBIN" >/dev/null 2>&1; then
        say "!! sing-box check провалился — откат"
        cp "$(ls -1t /root/sb-config-backup-*.json | head -1)" "$SBCFG"
        exit 1
    fi
    nginx_insert "$(domain)" || { say "!! не удалось вставить блок nginx"; exit 1; }
    if ! nginx -t >/dev/null 2>&1; then
        say "!! nginx -t провалился — откат nginx"
        nginx_remove >/dev/null
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
        exit 1
    fi
    systemctl reload nginx
    if ! reload_sb; then
        say "!! sing-box не поднялся — откат"
        cp "$(ls -1t /root/sb-config-backup-*.json | head -1)" "$SBCFG"
        systemctl restart sing-box.service
        exit 1
    fi
    say "== слушатели:"
    ss -lntp 2>/dev/null | grep -E ":($P_TRJ_GRPC|$P_VLESS_GRPC|$P_TRJ_XHTTP|$P_VLESS_XHTTP)\b" | awk '{print "  " $4}'
    say "== проба:"
    probe || say "ВНИМАНИЕ: проба не прошла — проверьте nginx/сертификат"
    say "OK: gRPC (/trj/, /vless/) и XHTTP (/trj-xhttp, /vless-xhttp) на 443"
    ;;
remove)
    say "== ssb-transport443: remove"
    backup
    nginx_remove
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    remove_inbounds
    sing-box check -C "$SBIN" >/dev/null 2>&1 || { say "!! конфиг сломан — откат"; cp "$(ls -1t /root/sb-config-backup-*.json | head -1)" "$SBCFG"; exit 1; }
    systemctl restart sing-box.service
    say "OK: удалено (443 снова только под сайт/подписки)"
    ;;
status)
    say "== ssb-transport443: status (домен: $(domain))"
    for t in "$T_TRJ_GRPC" "$T_VLESS_GRPC" "$T_TRJ_XHTTP" "$T_VLESS_XHTTP"; do
        if jq -e --arg t "$t" 'any(.inbounds[]?; .tag == $t)' "$SBCFG" >/dev/null 2>&1; then
            say "  inbound $t: есть"
        else
            say "  inbound $t: НЕТ"
        fi
    done
    if grep -q "$MARK_START" "$NGINX"; then say "  nginx-блок: есть"; else say "  nginx-блок: НЕТ"; fi
    ss -lntp 2>/dev/null | grep -E ":($P_TRJ_GRPC|$P_VLESS_GRPC|$P_TRJ_XHTTP|$P_VLESS_XHTTP)\b" | awk '{print "  listen " $4}'
    say "== проба:"
    probe && say "OK" || say "проба не прошла"
    ;;
*)
    echo "Использование: $0 {apply|remove|status}"; exit 1
    ;;
esac
