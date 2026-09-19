# OpenFlux Exit Node — Hub-модуль K.R.O.T.

Модуль запускает **выходную ноду OpenFlux** на роутере. Телефон с приложением
[OpenFluxAndroid](https://github.com/p1neappleXpress/OpenFluxAndroid) туннелирует
свой трафик через разрешённые (не блокируемые провайдером) транспорты
(Yandex Диск/Docs WS, Yandex Volga, MAX/OneMe DataChannel, Cups.online,
Mail.ru Docs) на роутер, а роутер выпускает его в интернет через свой WAN.

Upstream-проект: <https://github.com/p1neappleXpress/OpenFlux>
Как это работает у автора: <https://github.com/p1neappleXpress/OpenFlux/issues/44>

## Установка

1. K.R.O.T. → Hub → **OpenFlux Exit Node** → Install.
2. Перелогиниться в LuCI (обновятся меню и ACL).
3. Открыть **Services → OpenFlux**.

## Сборка бинарника

Upstream публикует сборки только для Android/iOS; Linux-бинарник собирается
из исходников (Go). Два пути:

- На машине разработки:
  `sh hub/openflux/build-binaries.sh [amd64|arm64|armv7|armv6|mipsle|mips|mips64le|all]`
  — скрипт клонирует upstream в `hub/openflux/OpenFlux`, собирает статические
  бинарники в `hub/openflux/dist/`.
- Разместить `dist/openflux-linux-<arch>` где-нибудь по HTTPS и вписать адрес в
  LuCI → Services → OpenFlux → Settings → **bin_base** (или
  `uci set krot_openflux.settings.bin_base='https://...'`).
- Либо скопировать бинарник напрямую на роутер:
  `scp dist/openflux-linux-arm64 root@router:/usr/lib/krot-openflux/bin/openflux`

Установщик при отсутствии бинарника оставит сервис остановленным и покажет
подсказку; после установки бинарника достаточно нажать **Restart** на странице
модуля.

## Настройка

- **Transport** — `yandex` / `vyandex` / `oneme` / `cupsonline` / `mailru`.
  Для `yandex|vyandex|mailru` нужен URL документа; для `oneme` — `max_token`
  и `max_uid`; для `cupsonline` — base64-список комнат, который печатает
  exit-нода при запуске.
- **Exit mode**:
  - `l3` — сырой SNAT/DNAT, одно TCP-соединение end-to-end, быстрее; нужен root
    (на OpenWrt он есть). Роутер сам ставит правило подавления kernel-RST
    (nftables `krot_openflux`, либо iptables при `use_iptables=1`).
  - `l4` — gVisor-прокси без root, двойная терминация TCP, медленнее.
- **codec** (`batched`|`legacy`) — должен совпадать с кодеком клиента
  (OpenFluxAndroid).
- **encryption_key** — опциональный общий секрет AES-256-GCM (обе стороны).

## Ограничения

- Один инстанс = один транспорт+URL; клиенты выбирают пару «транспорт + url»,
  поэтому разные телефоны = разные инстансы.
- В `l3` режиме egress IP лучше зафиксировать (`local_ip`), чтобы RST-фильтр
  был прицельным, а не общесистемным.

## Диагностика

- `logread -e krot-openflux`
- `/etc/init.d/krot-openflux status`
- `ubus call service list | jsonfilter -e '@["krot-openflux"]'`
- Состояние RST-фильтра: `nft list table ip krot_openflux`
  (или `iptables -nL KROT_OPENFLUX`)

## Локальное тестирование без пуша

```
scp -r hub/openflux root@router:/tmp/openflux
ssh root@router 'cd /tmp/openflux && OF_PAYLOAD_DIR=./files sh install.sh'
```

## Структура модуля

| Путь | Назначение |
|---|---|
| `/etc/config/krot_openflux` | UCI: settings + instance-секции |
| `/etc/init.d/krot-openflux` | procd-сервис (respawn, рестарт по смене конфига) |
| `/usr/lib/krot-openflux/bin/openflux` | бинарник exit-ноды |
| `/usr/lib/krot-openflux/openflux-run.sh` | runner: валидация, RST-фильтр, запуск CLI |
| `/etc/krot-openflux/` | state (ключи шифрования, root-only) |
| LuCI: Services → OpenFlux | страница модуля |
