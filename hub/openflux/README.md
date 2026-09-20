# OpenFlux Exit Node — Hub-модуль K.R.O.T.

Модуль запускает **выходную ноду OpenFlux** на роутере. Телефон с приложением
[OpenFluxAndroid](https://github.com/p1neappleXpress/OpenFluxAndroid) туннелирует
свой трафик через разрешённые (не блокируемые провайдером) транспорты
(Yandex Диск/Docs WS, Yandex Volga, MAX/OneMe DataChannel, Cups.online,
Mail.ru Docs) на роутер, а роутер выпускает его в интернет через свой WAN.

Upstream-проект: <https://github.com/p1neappleXpress/OpenFlux>
Как это работает у автора: <https://github.com/p1neappleXpress/OpenFlux/issues/44>

Модуль устроен как `hub/olcrtc`: собственная веб-панель на роутере
(http://<router-ip>/openflux/), без пункта в LuCI-меню, без ACL и rpcd.

## Установка

1. K.R.O.T. → Updates → Hub → **OpenFlux Exit Node** → Install.
2. Открыть **http://<router-ip>/openflux/** — никаких перелогинов не нужно
   (rpcd не перезапускается, LuCI-сессия не страдает).

## Бинарник

Порядок поиска бинарника при установке/обновлении:

1. Уже установленный `/opt/openflux/openflux` — пропускается.
2. `/tmp/openflux` — вручную положенный бинарник (как в issue #44: собрать из
   исходников, `scp -O openflux root@<router>:/tmp/openflux`, запустить install
   ещё раз).
3. Пейлоад модуля `files/bin/openflux-linux-<arch>`.
4. Пиннутый релиз `titovcode/krot` (тег `openflux-0.1.0`) — как у olcrtc.
5. Релизы upstream `p1neappleXpress/OpenFlux` (Linux-сборки там пока не
   публикуются).

Ручной путь (issue #44): собрать `openflux-linux-<arch>` скриптом
`hub/openflux/build-binaries.sh`, положить на роутер в `/opt/openflux/openflux`
(`chmod +x`) и рестартнуть сервис. Либо выложить по HTTPS и указать `bin_base`
на панели, затем нажать Update.

## Настройка (веб-панель)

- **bin_base** — URL с `openflux-linux-<arch>`; пусто = пиннутый релиз.
- **Подавление kernel-RST** — в l3 ядро шлёт RST на чужие соединения и рвёт
  туннель (issue #44); модуль ставит nft-таблицу `krot_openflux` (или
  iptables-цепочку `KROT_OPENFLUX` при `use_iptables=1`).
- **Инстансы** — один инстанс = один транспорт+URL = один телефон
  (issue #44: «одна ссылка = одно устройство»). Для второго телефона — вторая
  ссылка и второй инстанс. Инстанс хранит `local_ip` (egress IP для l3) и
  `listen_port` (SOCKS-порт для l4).
- На Android отключите Private DNS: OpenFlux пропускает только TCP, UDP/53 и
  DoT не маскируются.

## Диагностика

- `logread -e krot-openflux` (сервис), `logread -e openflux` (сам openflux)
- `/etc/init.d/krot-openflux status`
- Панель: http://<router-ip>/openflux/ (автообновление каждые 5с)
- RST-фильтр: `nft list table ip krot_openflux` (или `iptables -nL KROT_OPENFLUX`)

## Локальное тестирование без пуша

```
scp -r hub/openflux root@router:/tmp/openflux
ssh root@router 'cd /tmp/openflux && OF_PAYLOAD_DIR=. sh install.sh'
```

## Структура модуля (0.2.x)

| Путь | Назначение |
|---|---|
| `/etc/config/krot_openflux` | UCI: settings + instance-секции |
| `/etc/init.d/krot-openflux` | procd-сервис (respawn, рестарт по смене конфига) |
| `/opt/openflux/openflux` | бинарник exit-ноды |
| `/opt/openflux/openflux-run.sh` | runner: валидация, RST-фильтр, запуск CLI |
| `/opt/openflux/gen-state.sh` | перегенерация `/www/openflux/state.js` |
| `/www/openflux/` | веб-панель (index.html + state.js) |
| `/www/cgi-bin/openflux` | CGI-бэкенд панели (status/restart/save) |
| `/etc/openflux/` | state (ключи шифрования, root-only) |
