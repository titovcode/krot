# WARP + UDP-noise «Exit» — план интеграции в K.R.O.T.

Статус: **design / P0 (не устанавливается)**. Модуль сознательно ещё не добавлен в
`hub/index.json` и не имеет `module.json`: пока в каталоге лежит только план и
генератор конфига, Hub его не увидит.

---

## 0. TL;DR

- Присланный конфиг — это **штатный XTLS/Xray-core**, никаких форков: outbound
  `wireguard` (WARP) + `freedom` из двух ступеней:
  1. WARP-outbound содержит `streamSettings.sockopt.dialerProxy: "noise-out"` — то есть
     все свои пакеты он отдаёт «шумовому» outbound'у,
  2. `noise-out` (`freedom`) с массивом `settings.noises` — перед настоящим
     хендшейком WireGuard отправляет поддельный QUIC-пакет (hex) и N случайных
     пакетов 23–911 байт с паузами 1–3 мс. Для DPI это выглядит как QUIC-флап, а не
     как WireGuard handshake.
- В K.R.O.T. это логично оформить **hub-модулем `hub/warp`** (как `hub/openflux` /
  `hub/olcrtc`: свой install.sh, свой `/www/warp/`-панель, без LuCI/ACL/rpcd) и
  отдавать наружу двумя способами:
  - **socks** (по умолчанию, ноль правок ядра K.R.O.T.): `socks5://127.0.0.1:11080`
    как обычный сервер в K.R.O.T. — ядро уже умеет `socks4/4a/5` outbound
    (`sing_box_config_facade.sh:177`), значит WARP можно выбрать для правил/секций;
  - **tun** (опция, только Xray ≥ 26): inbound `tun` создаёт реальный `warp0`,
    и его можно указать в `egress_interface` у OpenFlux — это ровно тот сценарий,
    под который сделан коммит `58960060` (POINTOPOINT → `default dev IFACE` в table 473).
- Готовый к проверке артефакт P0: `hub/warp/gen-config.sh` — генерирует ровно такой
  JSON из UCI/env, без jq и python (только busybox).

---

## 1. Разбор присланного конфига

| Блок | Что делает | Нюансы, которые важны для нас |
|---|---|---|
| `outbounds[warp]` | `protocol: wireguard`: `secretKey`, `address[2]`, `mtu: 1280`, peer `bmXOC+F1…` = публичный ключ Cloudflare WARP, `endpoint: 162.159.192.1:500`, `keepAlive: 5`, `allowedIPs: 0.0.0.0/0, ::/0` | `reserved` в конфиге **отсутствует** (дефолт `[0,0,0]`). Ключи, полученные через Cloudflare API/wgcf, почти всегда требуют ненулевой `reserved` — без него WARP не поднимается. Это поле обязательно поддержать в UCI. |
| `outbounds[warp].streamSettings.sockopt.dialerProxy = "noise-out"` | WG-outbound ходит в сеть **через** freedom-outbound `noise-out` | Единственный способ включить шум: сам по себе `noises` в конфиге ничего не делает. Порядок тегов произвольный, но ссылка обязательна. |
| `outbounds[noise-out].settings.noises` | 1 × `hex` (поддельный QUIC-пакет) + 8 × `rand` 23–911 байт, `delay: 1-2` и `1-3` мс | `type` поддерживает `rand`, `str`, `base64`, `hex`. Правило «**noises пропускает порт 53**» (иначе ломается DNS) — это by design Xray. |
| `inbounds` | `socks` 127.0.0.1:10808 (`udp: true`) + `http` 127.0.0.1:10809, оба со `sniffing` http/tls | Локальный SOCKS — то, что нам и нужно для пути «socks». `udp: true` — чтобы WARP видел UDP напрямую (иначе QUIC/игры через `udp_over_tcp`). |
| `routing.rules` | всё (`tcp,udp`) → `warp` | Простая «всё наружу» схема; в K.R.O.T. нам нужен тот же дефолт, но с возможностью оставить `direct`. |
| `dns.servers` | 1.1.1.1/1.0.0.1 + v6 | WG-outbound требует **IP** для целей: резолв делает `settings.remoteDNS` (в конфиге не задан → дефолт Xray 1.1.1.1/1.0.0.1 и т.п., DNS идёт **внутри** туннеля). Прописывать в генераторе явно — предсказуемее. |

### 1.1 Что проверено фактически (не по памяти)

| Факт | Как проверено |
|---|---|
| `noises` и тип `hex` есть в `infra/conf/freedom.go` в теге **v25.1.30** | `curl …/v25.1.30/infra/conf/freedom.go` → `case "hex": // user input hex` |
| Тип `hex` добавлен PR XTLS/Xray-core **#4239** (merged 2025-01-02) | страница PR |
| inbound `tun` в **v25.1.30 отсутствует**, есть в **v26.3.27** | `infra/conf/tun.go` и `proxy/tun/tun.go`: 404 на v25.1.30, 200 на v26.3.27 (`name` по умолчанию `xray0`, `MTU` 1500) |
| opkg-фид OpenWrt **24.10.6**: `xray-core 25.1.30-r1` | Packages.gz фида |
| apk-фиды OpenWrt **25.12.0**: `xray-core 26.3.27-r1` в `packages` для x86_64, aarch64_cortex-a53, mipsel_24kc, arm_cortex-a7_neon-vfpv4, mips_24kc | листинги фидов |
| Апстрим-релиз XTLS: linux-ассеты `Xray-linux-{64,arm64-v8a,arm32-v7a,mips32,mips32le,mips64,mips64le,riscv64,…}.zip` | GitHub API `releases/latest` |

Вывод по матрице: **на обоих целевых релизах OpenWrt `xray-core` есть в штатном фиде**
(opkg 25.1.30 и apk 26.3.27), причём оба умеют `noises`; `tun`-режим доступен только
там, где Xray ≥ 26 (apk-фиды или пиннутый upstream-бинарь).

### 1.2 Грабли Xray, которые модуль обязан закрыть сам

1. **Таблица 10230.** WG-outbound сам поднимает kernel-TUN (IPv6-таблица 10230) при
   наличии CAP_NET_ADMIN. Второй WARP-outbound/второй инстанс Xray в ту же таблицу не
   влезет → «не подключается». Лечение: `settings.noKernelTun: true` при `>1` outbound
   и/или при использовании `tun`-inbound. Генератор ставит `noKernelTun` из UCI
   (по умолчанию `true` — предсказуемость важнее пары процентов производительности).
2. **`reserved`** — см. выше.
3. **`remoteDNS`** — цели внутри WG обязаны быть IP; без `remoteDNS` домены не поедут.
4. **Мультиинстанс** — один процесс Xray на модуль, N профилей WARP как N outbound'ов
   (иначе плодим таблицы/routing и панель усложняется).

---

## 2. Три сценария, ради которых это нужно

**A. WARP как «чистый» egress для OpenFlux (`egress_interface`).**
Телефоны заходят на exit-ноду роутера, а наружу она выпускает не своим серым WAN-IP,
а Cloudflare-WARP. Раньше это делалось kernel-интерфейсом (AmneziaWG/WireGuard,
`hub/openflux/README.md`, `openflux-run.sh:211-257`). WARP+noise — то же самое, but
**без kmod и без kernel-WG**: годится на роутерах без модуля, где нужен AmneziaWG.
Работает через `tun`-inbound Xray (≥26) → настоящий `warp0` → `ip rule` по uid
OpenFlux + `ip route … table 473` (уже реализовано в `openflux-run.sh`; POINTOPOINT-ветка
для `default dev IFACE` добавлена коммитом `58960060`).

**B. WARP как прокси-выход для правил K.R.O.T. (нулевые правки ядра).**
В ядре **уже есть** ровно нужный механизм: Action секции = **`outbound` («JSON outbound»)**,
поле `outbound_json` — «complete sing-box outbound object». Реализация:
`section.js:2840-2860` (поле + валидатор), `podkop:8222-8234` (ветка `action=outbound`),
`sing_box_config_facade.sh:446-457` → `add_raw_outbound`,
`sing_box_config_manager.uc:769-775` (тег outbound'а **всегда перезаписывается** на
`<section>-out`, свой `tag` в JSON не нужен), валидация —
`json_utils.uc:96-99` (`valid_outbound`: объект + строковый `type`).
Пример из штатного конфига (`krot/files/etc/config/podkop:50-55`):
`{"type":"socks","server":"127.0.0.1","server_port":1080,"version":"5"}`.

То есть: модуль держит локальный `socks5://127.0.0.1:11080` (это Xray), а в Rules
создаётся обычная секция с Action = JSON outbound и JSON'ом на этот порт. Бонус: тот же
JSON можно указать в «Download lists/updates/subscriptions via Proxy/VPN»
(`podkop:2739-2760` явно разрешает json-outbound-правило).

**C. Замена «серых» kernel-WG/AWG линков на userspace.**
Там, где сейчас стоит `kmod-amneziawg`, можно оставить Xray: то же шифрование,
другие (лучшие/худшие — мерить) свойства маскировки, ноль требований к ядру.

Чего этим **не** делаем: не трогаем ядро sing-box (у него свой WG outbound без
noise-маскировки), не заменяем основной прокси K.R.O.T., не лезем в LuCI-меню.

---

## 3. Почему hub-модуль, а не правки ядра

Контракт модуля (`hub/README.md`): `module.json` + `install.sh` [+ `update.sh`, `remove.sh`],
версия — из `VERSION`-файла, установка — из Hub-таба. `hub/index.json` — единственная точка
регистрации (`{"modules":["zapret","byedpi","adguard","olcrtc","openflux"]}`).

Образец — `hub/openflux`: всё генерируется install.sh'ом, панель статическая
(`/www/warp/index.html` + `state.js` + `cgi-bin`), LuCI/rpcd не затрагиваются — значит
сессии LuCI не рвутся при установке.

### 3.1 Что придётся дописать в ядре K.R.O.T. (маленький, но обязательный патч)

Сейчас определение «установлено/какая версия» в `krot/files/usr/lib/updater.sh` —
**хардкод по `component`**:

| Точка | Строки | Что добавить |
|---|---|---|
| `hub_detect_installed_version()` | `updater.sh:1823-1848` | `warp)` → `head -n 1 /opt/warp/VERSION` |
| `hub_module_installed_status()` | `updater.sh:1853-1890` | `warp)` → `is_warp_installed || return 1` + версия |
| новая `is_warp_installed()` | рядом с `is_openflux_installed` (`updater.sh:1914`) | `[ -x /etc/init.d/krot-warp ] && [ -x /opt/warp/warp-run.sh ]` |
| `hub_remove_module()` | `updater.sh:2318+` | ветка очистки (init-скрипт, `/opt/warp`, `/etc/warp`, `/www/warp`, nft-mark) |

Без этих четырёх правок модуль установится, но Hub покажет его как «не установлен» и
не покажет версию.

---

## 4. Структура модуля

```
hub/warp/
  module.json          # id=warp, component=warp, version=x.y.z
  install.sh           # opkg/apk xray-core | upstream zip fallback; init; UCI; панель; VERSION
  update.sh            # как в openflux: скачать install.sh и выполнить
  remove.sh            # stop+disable, удалить nft-правило, файлы (WARP_PURGE=1 → и конфиг)
  DESIGN.md            # этот документ
  gen-config.sh        # ГЕНЕРАТОР JSON (P0, уже есть) — единственный источник правды для Xray
  files/
    etc/init.d/krot-warp
    usr/lib/krot-warp/warp-run.sh     # обёртка procd: mark/bypass → gen-config → xray -test → exec
  www/warp/{index.html,state.js,cgi-bin}
```

Пути на роутере (по образцу OpenFlux):

| Путь | Назначение |
|---|---|
| `/opt/warp/xray` | бинарь (или симлинк на `/usr/bin/xray` из пакета) |
| `/opt/warp/warp-run.sh` | раннер инстанса |
| `/opt/warp/VERSION` | версия модуля (для Hub) |
| `/etc/config/krot_warp` | UCI: `settings` + профили WARP |
| `/etc/warp/<profile>.json` | сгенерированный конфиг Xray (0600, `umask 077`) |
| `/etc/warp/<profile>.key` | приватный ключ (0600) — в JSON не дублировать |
| `/www/warp/` | панель + `state.js` |
| `/www/cgi-bin/warp` | CGI-бэкенд панели (status/restart/save/register) |


---

## 5. Рецепт для пользователя (то, что делает UI после установки модуля)

1. Hub → **WARP (Xray)** → Install. Модуль ставит Xray, поднимает профиль
   `warp` и слушает локальный SOCKS.
2. Rules (Sections) → **Add section** → Action = **JSON outbound** → вставить:

```json
{"type":"socks","server":"127.0.0.1","server_port":11080,"version":"5"}
```

   (если нужен QUIC/UDP через WARP — добавить `"network":"tcp"` и/или
   `"udp_over_tcp":true`; без `network` sing-box отдаёт и TCP, и UDP)
3. Conditions — домены/IP/подписки, которым нужен выход через WARP.
4. Всё. Правок в sing-box-конфиг не требуется: ядро само положит этот outbound
   с тегом `<section>-out` (`add_raw_outbound`) и заведёт route-rule.

### 5.1 Что модуль обязан сделать, чтобы это работало надёжно

| Требование | Почему |
|---|---|
| SOCKS только на `127.0.0.1` (по умолчанию) | иначе порт торчит в LAN |
| uid-скоупный mark `meta skuid <warp-uid> meta mark set 0x00200000` в `inet KrotTable mangle_output` | K.R.O.T. помечает трафик к «провайдерским» подсетям (`NFT_FAKEIP_MARK`) и может загнать UDP к `162.159.192.1:500` в tproxy → WARP не поднимется. `NFT_OUTBOUND_MARK` объявлен в `krot/files/usr/lib/constants.sh:34`. **Blanket `skuid 0` ставить нельзя** — это уже проходили в openflux 0.2.7 (`openflux-run.sh:170-190`: правило «глушит» весь root-трафик, включая sing-box). |
| `xray -test -c` перед `exec` | не поднимать сервис с битым JSON (procd иначе уйдёт в respawn-цикл) |
| `VERSION` файл + `noKernelTun` | Hub-версия и отсутствие конфликта по таблице 10230 |
| `remoteDNS` в конфиге | цели внутри WG обязаны быть IP, домены резолвятся DNS'ом **внутри** туннеля |
| DNS: не подмешивать WARP в `dns_server` K.R.O.T. | DNS K.R.O.T. живёт в sing-box; WARP-DNS внутри xray — отдельная история. Если хочется «DNS через WARP» — отдельная секция с JSON-outbound на тот же порт и правилом по 53-му порту. |

### 5.2 Почему нельзя просто «добавить Xray-инбаунд в sing-box»

Ядро K.R.O.T. — sing-box. У sing-box есть `wireguard`-outbound, но **нет**
маскировки UDP-шумом (`noises`) и нет `dialerProxy`. Поэтому Xray живёт отдельным
процессом-сайдкаром, а стык идёт через локальный SOCKS — это минимально инвазивно
и не требует форка ядра.


---

## 6. Генератор конфига (`hub/warp/gen-config.sh`)

Уже в репозитории, P0-артефакт. POSIX sh, без jq/python (только busybox).
Источники значений: UCI `krot_warp.<section>.<opt>` → env-override `WARP_<OPT>`
(удобно тестировать на Mac/роутере без UCI). Пишет JSON в stdout.

```sh
# локально, без роутера
WARP_PRIVATE_KEY='...' WARP_ADDRESSES='172.16.0.2/32' \
WARP_PEER_PUBLIC_KEY='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' \
./hub/warp/gen-config.sh warp > /tmp/warp.json
python3 -m json.tool < /tmp/warp.json >/dev/null && echo 'JSON OK'
```

| UCI | env | Смысл | Дефолт |
|---|---|---|---|
| `private_key` | `WARP_PRIVATE_KEY` | приватный ключ WARP (**обязателен**) | — |
| `addresses` | `WARP_ADDRESSES` | `addr/32[,v6/128]` | — |
| `peer_public_key` | `WARP_PEER_PUBLIC_KEY` | ключ пира | WARP-константа |
| `endpoint` | `WARP_ENDPOINT` | адрес пира | `162.159.192.1:500` |
| `mtu` | `WARP_MTU` | MTU внутренних пакетов | `1280` |
| `reserved` | `WARP_RESERVED` | три байта через запятую | `0,0,0` |
| `keepalive` | `WARP_KEEPALIVE` | persistent keepalive, сек | `5` |
| `no_kernel_tun` | `WARP_NO_KERNEL_TUN` | `1` → `noKernelTun: true` | `1` |
| `listen_port` | `WARP_LISTEN_PORT` | SOCKS-порт | `11080` |
| `http_port` | `WARP_HTTP_PORT` | HTTP-инбаунд (пусто = выкл) | `11089` |
| `remote_dns` | `WARP_REMOTE_DNS` | DNS внутри туннеля (`off` → ключ не пишется) | `1.1.1.1,1.0.0.1` |
| `dns_servers` | `WARP_DNS_SERVERS` | блок `dns.servers` Xray (`off` → блок не пишется) | `1.1.1.1,1.0.0.1` |
| `noise_enabled` | `WARP_NOISE_ENABLED` | `1/0` — весь массив `noises` | `1` |
| `noise_hex` | `WARP_NOISE_HEX` | hex-пакет QUIC-мимикрии (`off` → без него) | `hub/warp/noise-quic.hex` |
| `noise_rand` / `noise_count` / `noise_delay` | `WARP_NOISE_RAND` / `_COUNT` / `_DELAY` | случайные пакеты | `23-911`, `8`, `1-3` |
| `log_level` | `WARP_LOG_LEVEL` | `loglevel` Xray | `warning` |
| `tun_mode` | `WARP_TUN_MODE` | `1` → inbound `tun` (Xray ≥ 26) | `0` |
| `tun_name` | `WARP_TUN_NAME` | имя интерфейса для `egress_interface` | `warp0` |
| `add_direct` | `WARP_ADD_DIRECT` | `1` → добавить outbound `direct` | `0` |

«Выключено» задаётся явным маркером (`off` / `none` / `no` / `-`), потому что UCI не
отличает пустое значение от отсутствующего, а пустой env — это «не переопределяй».
Отладка без роутера: `KROT_WARP_UCI=/tmp/krot_warp` подменяет путь к UCI-файлу.

Генератор падает с ненулевым кодом на отсутствующих/некорректных значениях
(`private_key`, `addresses`, `reserved` вне 0..255, нечисловые `mtu`/порты,
имя tun длиннее 15 символов) — лучше явная ошибка в `logread`, чем respawn-цикл.
Валидацию самой схемы делает Xray в раннере: `xray -test -c /etc/warp/<profile>.json`.

---

## 7. Фазы

| Фаза | Содержание | Оценка |
|---|---|---|
| **P0** (есть) | `DESIGN.md` + `gen-config.sh`, проверка JSON | сделано |
| **P1** | `hub/warp/{module.json,install.sh,update.sh,remove.sh}` + `files/etc/init.d/krot-warp` + `files/usr/lib/krot-warp/warp-run.sh`; SOCKS-режим; mark-правило; патч `updater.sh` (4 точки из §3.1); запись в `hub/index.json` | 1 сессия |
| **P2** | Панель `/www/warp/` (статус/логи/профили/тест-кнопка `xray -test`), `tun`-режим + связка с OpenFlux `egress_interface`, `Download via proxy` recipe | 1–2 сессии |
| **P3** | Регистрация WARP-аккаунта одной кнопкой (Cloudflare API `api.cloudflareclient.com/v0a…/reg` → `reserved` + `addresses`), несколько WARP-профилей (мульти-egress для OpenFlux) | позже |

---

## 8. Риски / открытые вопросы

1. **Ключ из присланного конфига надо считать скомпрометированным** — он прошёл через
   чат и, возможно, скопирован из публичной подборки. Сгенерировать новый
   (`xray wg` / wgcf / регистрация в API) и хранить в `/etc/warp/*` c `0600`;
   в git, в UCI-дефолтах и в панели ключ показывать только root-пользователю.
2. **Репутация WARP-IP**: Cloudflare-диапазоны часть российских сервисов режет
   (капчи, «недоступно в вашем регионе»). WARP — это «чистый exit», а не «обход РФ-блокировок».
3. **`noises` ломает часть UDP-сценариев** — шум может рвать чужой QUIC/игровой трафик;
   держать `noise_*` настраиваемыми и выключаемыми (`WARP_NOISE_HEX='' WARP_NOISE_COUNT=0`).
4. **24.10 (opkg) даёт Xray 25.1.30 → `tun`-инбаунда нет.** Значит на 24.10 — только
   SOCKS-путь; `tun`-путь + OpenFlux egress требует apk-релиз (26.3.27) или
   пиннутый апстрим-бинарь из `XTLS/Xray-core` releases (`Xray-linux-*.zip`).
5. **Порядок старта**: xray должен слушать SOCKS раньше, чем sing-box начнёт соединения
   по правилу (иначе ошибки dial в логе K.R.O.T.). Смягчение — `START=` в init-скрипте
   + мягкий статус в панели (sing-box переподключается per-connection, фатально не ломается).
6. **Размер**: `Xray-linux-64.zip` ~21 МБ, установленный бинарь ~28 МБ — на роутерах с
   маленьким overlay ставить в `/opt` (extroot) или предупредить в панели.


---

## 9. Что уже проверено локально (2026-09-26)

Проверял не «на глаз»: конфиг от генератора прогнан через **настоящий Xray 26.3.27**
(`Xray-macos-arm64-v8a.zip`, `xray -test -c`).

| Проверка | Как | Результат |
|---|---|---|
| Синтаксис | `sh -n hub/warp/gen-config.sh` | OK |
| Структура | генератор + `python3 -m json.tool` + asserts | `dialerProxy=noise-out`; 9 noises (1×hex 1252 байта + 8×rand `23-911`); `reserved`, `remoteDNS`, порты 11080/11089, route-rule `tcp,udp → warp` — совпадают со схемой присланного конфига |
| Реальная схема | `xray -test -c c1.json` (дефолт) | **`Configuration OK.`** |
| Выключение шума | `WARP_NOISE_ENABLED=0 WARP_HTTP_PORT=` | `Configuration OK.`, ключ `noises` отсутствует |
| `reserved` + без `remoteDNS` | `WARP_RESERVED=1,2,3 WARP_REMOTE_DNS=off` | `Configuration OK.`, ключ `remoteDNS` не пишется |
| Негатив: битый hex | `WARP_NOISE_HEX=zz-not-hex` | `infra/conf: Invalid hex string` (exit 23) — гейт `xray -test` поймает до старта сервиса |
| Негатив: битый delay | `WARP_NOISE_DELAY=abc` | `Invalid integer range, expected either string of form "1-2" or plain integer` |
| Негатив: reserved | `WARP_RESERVED=1,2,300` | генератор: `reserved[3] is out of range [0..255]`, exit 1 |
| UCI-ветка (эмуляция роутера) | фейковый `uci` в `PATH` + `KROT_WARP_UCI=/tmp/krot_warp` | значения подхватились: `reserved=[12,34,56]`, socks `:12080`, inbound `tun-in{name=warp9}` |
| `tun_mode=1` на macOS | `xray -test` + запуск | конфиг валиден, но darwin-бинарь требует имя `utunN` (`interface name must be utunN, where N is a number`) — на Linux/OpenWrt `warp0` корректен. Значит `tun`-путь проверяется **только на роутере**. |

Не проверено (нужен роутер и новый валидный ключ): реальное поднятие туннеля WARP,
сквозной трафик через секцию K.R.O.T. с JSON-outbound, `egress_interface` у OpenFlux.

