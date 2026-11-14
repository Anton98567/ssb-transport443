# ssb-transport443 — gRPC и XHTTP на 443 для нод SSB

Дополнение к [Secret-Sing-Box](https://github.com/A-Zuro/Secret-Sing-Box): те же
Trojan и VLESS, но вместо WebSocket — **gRPC** и **XHTTP-подобный HTTP/2**. Оба
транспорта живут **на 443**, рядом с обычным сайтом ноды, без base64 в командах
установки и без изменения существующих заказов.

```
клиент ──TLS 1.3 + HTTP/2──► nginx :443 ──h2c (grpc_pass)──► sing-box 127.0.0.1:20443..20446 ──► персональный OUT заказа
```

## Что даёт

| Путь на 443 | Инбаунд (loopback) | Протокол | Транспорт |
|---|---|---|---|
| `/trj/`, `/trj` | `127.0.0.1:20443` | Trojan | gRPC (`service_name: trj`) |
| `/vless/`, `/vless` | `127.0.0.1:20444` | VLESS | gRPC (`service_name: vless`) |
| `/trj-xhttp` | `127.0.0.1:20445` | Trojan | HTTP/2 (`path: /trj-xhttp`) |
| `/vless-xhttp` | `127.0.0.1:20446` | VLESS | HTTP/2 (`path: /vless-xhttp`) |

TLS терминирует nginx (сертификат Let's Encrypt ноды), в sing-box трафик уходит
по **h2c** через `grpc_pass` — поэтому инбаунды слушают только loopback и наружу
не открыты. Порт 443 остаётся обычным HTTPS-сайтом ноды: active probing видит
сайт/заглушку, а не туннель.

## Важное ограничение: XHTTP

**В sing-box нет XHTTP.** Это транспорт Xray-core (`type: xhttp`, режимы
`packet-up`/`stream-up`/`stream-one`, `xpadding`). Ближайший эквивалент в sing-box —
собственный транспорт `http` (HTTP/2 POST-стрим с путём и Host), он и используется:
поведенчески это то же самое — запросы идут как обычный HTTP/2 к тому же домену на
443. Файлы названы `-XHTTP-`, чтобы не путать с WS, но внутри — `transport.http`.

Практическое следствие: конфиги понимают sing-box-совместимые клиенты (Karing,
Hiddify, SFA/SFI, sing-box CLI). Если нужен именно Xray-XHTTP с padding — это
другая реализация, здесь её нет.

## Установка

Одна строка — поставить, включить gRPC+XHTTP на 443 и выдать конфиги заказа:

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh \
  | bash -s -- --apply --order ORDER-123456 --count 10 --out out-123456
```

Оба транспорта (gRPC и XHTTP) выдаются по умолчанию — это 10 × 2 файла × 2 протокола
(TRJ+VLESS) = 40 конфигов. Нужен только один транспорт:

```bash
# только gRPC
curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh \
  | bash -s -- --apply --order ORDER-123456 --schemes grpc

# только XHTTP (HTTP/2)
curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh \
  | bash -s -- --apply --order ORDER-123456 --schemes xhttp
```

Только поставить скрипты, без изменений в ноде:

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-transport443/main/install.sh | bash
```

Флаги: `--apply`, `--order ORDER-…`, `--count N` (1…50), `--out out-…`
(по умолчанию `out-<номер заказа>`), `--schemes both|grpc|xhttp`, `--name <база>`,
`--status`, `--help`.

Ставит:

* `/usr/local/bin/ssb-transport443-patch` — включить/выключить/проверить схему;
* `/usr/local/bin/ssb-transport443-add` — выдача конфигов заказа;
* `/usr/local/share/ssb-transport443/tpl.json` — клиентский шаблон (та же
  маршрутизация, что в боевом `template.json` ноды).

Требования: уже установленный SSB (nginx на 443 с LE-сертификатом, sing-box ≥ 1.11,
`python3`, `jq`, `curl`), root.

## Использование

```bash
# 1. Включить gRPC + XHTTP на 443 (идемпотентно, с бэкапами и откатом при ошибке)
ssb-transport443-patch apply

# 2. Проверить состояние и ответы путей
ssb-transport443-patch status

# 3. Выдать конфиги заказа (по умолчанию 10 x TRJ+VLESS x gRPC+XHTTP = 40 файлов)
ssb-transport443-add ORDER-123456 10 out-123456

# только один транспорт
SCHEMES=grpc  ssb-transport443-add ORDER-123456 10 out-123456
SCHEMES=xhttp ssb-transport443-add ORDER-123456 10 out-123456

# своя база имени конфигов
ssb-transport443-add ORDER-123456 3 out-123456 name=phone

# 4. Полный откат (443 снова только под сайт)
ssb-transport443-patch remove
```

Результат `add`: каталог `/root/ssb-transport443-out/<ORDER>/` с JSON-файлами и
двумя списками ссылок:

* `links-by-user.txt` — блок на каждого клиента: имя пользователя и его 4 ссылки
  (TRJ-GRPC, VLESS-GRPC, TRJ-XHTTP, VLESS-XHTTP) — это то, что выдаётся в тикет;
* `links-all.txt` — плоский список всех ссылок по транспортам.

Файлы также копируются в секретный каталог ноды, поэтому ссылки вида
`https://<домен>/<секрет-путь>/<ORDER>-xxxx-TRJ-GRPC-CLIENT.json` отдаются по HTTPS
без авторизации (сам путь — секрет).

`apply` идемпотентен и **не ломает уже выданные заказы**: при повторном запуске
инбаунды пересоздаются с теми же пользователями (seed-пользователь добавляется
только если список пуст). Поэтому `apply` можно безопасно повторять после
обновления скриптов.

В правило `ip_cidr` клиентского конфига подставляется реальный IP ноды (резолв
домена в момент генерации) — это пиннинг против DNS-спуфинга. Если домен не
резолвится, пиннинг просто отключается, а не ломает конфиг.

## Политика OUT

**Каждый заказ — только через свой персональный OUT** (`out-<номер заказа>`).
Скрипт отказывается работать, если указанного OUT нет в конфиге. Правило маршрута
дописывается **перед** финальным `{"action": "reject"}` — иначе трафик заказа
попадёт в reject (частый источник «туннель поднялся, но интернета нет»).

Тег `direct` допустим только для тестов на отдельной машине.

## Маршрутизация клиента

Шаблон повторяет боевой `template.json` 1-в-1: 32 rule-set, `sniff` → `hijack-dns`,
порт 853 и `encrypted-dns` в reject, реклама в reject, bypass-приложения (530
банков/Госуслуг/маркетплейсов), MAX/VK/ростел, `.ru`/`.su` и `geoip-ru` в direct,
`resolve` перед `geoip-ru`, финальное правило `inbound: tun-in → proxy`.

Перед генерацией каждый rule-set проверяется по факту:

1. файл есть в каталоге rule-set ноды → локальный URL (быстро, без внешних запросов);
2. иначе — публичный источник ([A-Zuro/sb-rule-sets](https://github.com/A-Zuro/sb-rule-sets),
   [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite),
   [SagerNet/sing-geoip](https://github.com/SagerNet/sing-geoip)), если отвечает 200;
3. иначе набор выбрасывается вместе с правилами route/dns, которые на него ссылаются.

Причина: клиент не стартует, если хотя бы один `rule_set` отдаёт 404 —
`initial rule-set: <tag>: unexpected status: 404 Not Found`. В лог печатается
`rule-set: N из M`, а про отброшенные — предупреждение.

## Проверка после установки

```bash
ssb-transport443-patch status      # 4 инбаунда, nginx-блок, 4 ответа 200
ss -lntp | grep 2044              # слушатели только на 127.0.0.1
curl -sk -o /dev/null -w '%{http_code}\n' https://<домен>/   # 200/401 — обычный сайт
```

Сквозной тест: скачать выданный конфиг, поднять его локальным sing-box с
`inbounds[].tag = tun-in` (шаблон маршрутизирует по этому тегу) и проверить
`https://api.ipify.org` — должен вернуться IP выходного сервера, а не клиента.

## Грабли (учтены в скриптах)

* **`inbound: tun-in` в финальном правиле.** Если клиент поднимает инбаунд с другим
  тегом, трафик уходит в `direct` (первый outbound) и «VPN не работает». В тестах
  тег надо называть `tun-in`, как это делают боевые клиенты.
* **`reject` должен быть последним правилом.** Правила заказов вставляются перед ним.
* **`reload` sing-box может молча не примениться** — после изменений проверяется
  `systemctl is-active`, при неудаче делается `restart`.
* **`/etc/sing-box` парсит все `*.json`** в каталоге: посторонний файл (например,
  `reality.json` с ключами) ломает старт.
* **`grpc_buffering`/`grpc_request_buffering` не существуют** в nginx 1.30 — не
  добавляйте, конфиг не пройдёт `nginx -t`.
* **`nginx -t` и `sing-box check` перед reload**; при провале — автоматический
  откат из бэкапа (`/root/sb-config-backup-*`, `/root/nginx.conf.bak-*`, хранятся
  последние 10).
* **443 занят**: блок вставляется перед `location @ws_proxy` существующего сервера,
  отдельный `server {}` не создаётся.

## Совместимость протоколов

| Транспорт | Trojan | VLESS | Примечание |
|---|---|---|---|
| gRPC | да | да | HTTP/2, `service_name`, ALPN `h2` |
| HTTP/2 (`-XHTTP-`) | да | да | HTTP/2 POST-стрим, `path` + `Host` |
| WebSocket | — | — | остаётся в базовом SSB, здесь не трогается |

На каждый конфиг заказа выдаётся 4 файла (`TRJ-GRPC`, `VLESS-GRPC`, `TRJ-XHTTP`,
`VLESS-XHTTP`) с общими для пары логином/паролем или UUID.

## Удаление

```bash
ssb-transport443-patch remove
rm -f /usr/local/bin/ssb-transport443-{patch,add}
rm -rf /usr/local/share/ssb-transport443
```

## Лицензия

MIT.
