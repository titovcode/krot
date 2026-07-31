# Whitelist Bypass — модуль K.R.O.T. Hub

Мобильный интернет через платформы из «белого списка» (Яндекс Телемост, VK Звонки, WB Stream, DION).
Роутер с K.R.O.T. поднимает headless-creator из проекта
[whitelist-bypass](https://github.com/kulikov0/whitelist-bypass), а телефон подключается
по QR-коду со страницы модуля в LuCI.

```
Телефон (РФ, белые списки)                Роутер с K.R.O.T. (creator)
  whitelist-bypass app -- QR --> joiner
        |                                     |
   DataChannel/VP8 через SFU Яндекса/VK (в белом списке)
        |                                     |
        +-------- туннель -------->  egress: direct или через правила K.R.O.T.
                                              (upstream_socks = 127.0.0.1:4534)
```

## Установка

1. K.R.O.T. → Hub → **Whitelist Bypass (mobile)** → Install.
2. Перелогиньтесь в LuCI (обновятся меню и ACL).
3. Откройте **Services → WLB: Mobile bypass**.

Бинарники ставятся из релизов `kulikov0/whitelist-bypass` (x64/ia32 — прямые ассеты,
arm/mips — из CLI-бандла). Архитектура определяется автоматически.
Нужные платформы можно ограничить: `WLB_PLATFORMS="telemost vk"` перед установкой
(экономия флеша: один creator ≈ 15–25 МБ).

Свои бинарники: `./build-binaries.sh` на десктопе (нужен Go), дальше либо
`scp dist/krot-wlb/linux-<arch>/headless-*-creator root@router:/usr/lib/krot-wlb/bin/`
(установщик увидит их и пропустит скачивание), либо `WLB_BIN_BASE=http://.../linux-<arch>`.

## Настройка (UX как в ТЗ)

1. **Авторизация (cookies)** — два способа:
   - **QR Login (Яндекс, рекомендуется).** Кнопка **QR Login** в строке Yandex:
     роутер показывает QR, вы сканируете его приложением Яндекса (где уже
     залогинены), подтверждаете вход — куки сами сохраняются в
     `/etc/krot-wlb/cookies-yandex.json` (mode 600), инстансы перезапускаются.
     Пароль нигде не вводится. Реализовано в `wlb-yandex-login.sh` по схеме
     passwordless-входа Яндекс.Паспорта (`pwl-yandex` → magic code → session).
   - **Вручную.** Куки из десктопного приложения whitelist-bypass (кнопка
     *Export Cookies*) или расширения браузера (Cookie-Editor → export JSON),
     кнопка **Paste**.
2. **Add mobile device** — роутер создаёт видеозвонок и держит его открытым.
3. **QR** — сканируйте мобильным приложением whitelist-bypass → GO.
4. Готово: весь трафик телефона выглядит как видеозвонок.

> ⚠️ **Один instance = один телефон** (ограничение whitelist-bypass: одна конференция
> обслуживает ровно одного joiner-а). Для второго телефона добавьте ещё один instance.

## Если ссылка обновилась — куда её кидать автоматически

Watcher в `wlb-run.sh` следит за link-файлом. При смене ссылки дергается
`wlb-notify.sh`, который шлёт её во все настроенные цели разом:

- **На Мак (и iPhone/Android): ntfy.** Укажите `https://ntfy.sh/<секретный-топик>` —
  придёт push в приложение ntfy (есть для macOS/iOS) со ссылкой, клик — и вы в приложении.
  Можно и self-hosted ntfy.
- **В Telegram:** токен бота (@BotFather) + chat id. Если Telegram режется на WAN,
  включите «Notify via K.R.O.T. proxy» — отправка пойдёт через локальный прокси
  K.R.O.T. (127.0.0.1:4534) по вашим правилам.
- **Куда угодно: custom command.** Произвольная команда, ссылка в `$WLB_LINK`:
  ```sh
  # пример: положить ссылку на Мак и показать нотификацию
  echo "$WLB_LINK" | ssh mac@192.168.1.50 'cat > ~/wlb-link.txt && osascript -e "display notification \"$WLB_LINK\" with title \"WLB link\""'
  ```
- Кнопка **⇪** в списке инстансов — принудительно разослать текущую ссылку.

Ссылка при этом остаётся стабильной: при перезапусках creator по возможности
пере-подключается к той же конференции (`rejoin`), а уведомление приходит только
когда ссылка реально сменилась.

## Egress через правила K.R.O.T.

Поле **Upstream SOCKS** = `127.0.0.1:4534` заворачивает трафик туннеля в sing-box
КРОТа — телефон получает маршрутизацию по вашим спискам/правилам. Пусто = напрямую
в интернет роутера.

## Структура модуля

| Путь | Назначение |
|---|---|
| `/etc/config/krot_wlb` | UCI: settings + instance-секции |
| `/etc/init.d/krot-wlb` | procd-сервис (respawn, рестарт по смене конфига) |
| `/usr/lib/krot-wlb/bin/` | headless-*-creator бинарники |
| `/usr/lib/krot-wlb/wlb-run.sh` | runner: rejoin конфы, watcher ссылки, notify |
| `/usr/lib/krot-wlb/wlb-notify.sh` | Telegram / ntfy / custom-команда |
| `/etc/krot-wlb/cookies-*.json` | куки платформ (mode 600) |
| `/etc/krot-wlb/state/<id>.link` | последняя ссылка (для rejoin после ребута) |
| `/var/run/krot-wlb/<id>.link` | активный link-файл (--write-file) |
| LuCI: Services → WLB: Mobile bypass | страница модуля |

## Диагностика

```sh
logread -e krot-wlb            # логи creator-ов и нотификатора
/etc/init.d/krot-wlb status
ubus call service list         # procd-инстансы
```

## Локальное тестирование без пуша в GitHub

```sh
scp -r hub/whitelist-bypass root@router:/tmp/wlb
ssh root@router 'cd /tmp/wlb && WLB_PAYLOAD_DIR=./files sh install.sh'
```
