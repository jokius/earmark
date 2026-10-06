# earmark

[English](README.md) · **Русский**

[![CI](https://github.com/jokius/earmark/actions/workflows/ci.yml/badge.svg)](https://github.com/jokius/earmark/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)

Приложение в строке меню macOS, которое пишет созвоны: ваш микрофон и собеседники (системный
звук) ложатся на раздельные каналы. Запись сама стартует за минуту до события из выбранных
календарей, сама останавливается, когда приложение созвона отпускает микрофон, ложится в папку
своего календаря и локально расшифровывается через whisper.cpp в диалог «Я / Собеседники».
Как [Anarlog](https://github.com/fastrepl/anarlog), только без мишуры: ни AI-саммари, ни облака,
ни окна настроек — всё управляется командой `earmark`, вами или вашим агентом.

## Что умеет

- **Два канала.** Микрофон — левый канал, все остальные (системный звук) — правый. Итог —
  стерео AAC `audio.m4a`, 48 кГц, около 43 МБ на час.
- **Стартует сам** за `lead_seconds` (по умолчанию 60 с) до каждого события включённых
  календарей. События на весь день, отменённые и отклонённые пропускаются. Опоздали — запись всё
  равно начнётся, пока событие не кончилось. Ручной старт — из меню, CLI или агентом.
- **Останавливается сам**, когда созвон кончился и приложение отпустило микрофон. Страховки:
  событие кончилось и затихли обе стороны, долгая тишина, потолок 5 часов.
- **Переживает крэш.** Во время записи звук идёт в устойчивые к обрыву LPCM CAF. После крэша
  или пропавшего питания следующий запуск сводит записанное и помечает запись `recovered`.
  Выход из приложения посреди записи работает так же: запись доведёт следующий запуск.
- **Папка на календарь**: `~/Earmark/<Календарь>/2026-10-02 14-00 Daily sync/`.
- **Локальная расшифровка** whisper.cpp с моделью large-v3-turbo (beam search, детект голоса),
  отдельным процессом после созвона.
- **CLI на всё** — настройки, статус, записи, транскрипты — с выводом в JSON, плюс skill для
  Claude Code и MCP-сервер для Codex и других MCP-клиентов.

## Чего не делает

- Ни AI-саммари и заметок, ни напоминаний о встречах, ни облака и синхронизации.
- Ни окна настроек, ни редактора транскриптов: есть значок в строке меню и CLI.
- Ни хуков «после записи»: ждите появления `audio.m4a` или `transcript.json` либо опрашивайте
  `earmark recordings --status transcribed`.
- Пока без разделения собеседников по голосам: все на той стороне — «Собеседники».
- Пока без эхо-фильтра: при звуке из динамиков голос собеседников попадает в микрофон и
  дублируется под «Я». Пользуйтесь наушниками.
- В сеть не ходит, кроме разовой загрузки модели Whisper с Hugging Face (`earmark model import`
  обходится и без неё).

## Требования

- macOS 15 или новее. Собирается под 15+, проверено на macOS 27.
- Xcode 27 (Swift 6.4) и [xcodegen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`). Опционально [swiftlint](https://github.com/realm/SwiftLint) — без
  него сборка в Xcode только предупреждает, но `make lint` и `make check` без него не работают.
- Около 2 ГБ свободного места под модель.

## Сборка и установка

```sh
make            # собрать
make test       # прогнать тесты
make check      # формат, линт и тесты
make install    # релиз в /Applications, CLI — симлинком в ~/.local/bin/earmark
```

`.xcodeproj` в репозитории нет: он генерируется из `project.yml` при каждой сборке.

### Подпись

По умолчанию сборка идёт с ad-hoc подписью. Она работает, но macOS после каждой пересборки
заново спрашивает микрофон, системный звук и календари: у ad-hoc меняется cdhash, и выданное
разрешение перестаёт совпадать. Hardened Runtime включается только в подписанной сборке: при
ad-hoc подписи его library validation не пустила бы whisper.framework в CLI.

Чтобы разрешения держались, укажите свою команду в `signing.local` (он не отслеживается гитом):

```make
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = <поле OU сертификата>
```

Родовое имя вместо хеша сертификата — намеренно: Xcode сам возьмёт актуальный, поэтому
истечение или замена сертификата ничего не ломают. Team ID берётся из поля `OU` сертификата,
а не из скобок в его названии — это разные значения.

### Первый запуск

1. `make install` кладёт `Earmark.app` в `/Applications` и делает симлинк CLI
   `~/.local/bin/earmark`. Проверьте, что `~/.local/bin` есть в `PATH`. Запустите Earmark из
   `/Applications` один раз: он сам добавится в автозапуск (`launch_at_login`).
2. Выдайте права: значок в строке меню → **Grant Permissions…** или `earmark permissions request`.
   macOS спросит микрофон, полный доступ к календарям и запись системного звука (Системные
   настройки → Конфиденциальность и безопасность → Запись экрана и системного аудио → «Только
   запись системного аудио»).
3. Выберите календари — пока не выберете, ничего не пишется:

   ```sh
   earmark calendars                 # id, названия, аккаунты
   earmark calendars enable <id>
   earmark upcoming                  # что запишется в ближайшие 24 часа
   ```

4. Модель (1,6 ГБ): `earmark model download` или `earmark model import <путь>`, если
   `ggml-large-v3-turbo.bin` уже есть (сверяется по SHA-256 и на APFS клонируется, а не копируется).
5. Проверьте всё разом: `earmark doctor --audio-test`.
6. По желанию задайте язык расшифровки и подписи собеседников. Из коробки Whisper определяет
   язык каждой записи сам (`auto`), а в транскрипте стоят `Me` и `Them`. Для созвонов на русском,
   например:

   ```sh
   earmark config set transcription.language ru
   earmark config set transcript.label_me "Я"
   earmark config set transcript.label_them "Собеседники"
   ```

Записи ложатся в `~/Earmark`, папка создаётся с правами 0700. Поменять —
`earmark config set recordings_dir <путь>`. Desktop, Documents и Downloads не принимаются: их
охраняет macOS, и любой скрипт, читающий записи, упирался бы в запросы прав.

## CLI

Каждая команда печатает JSON. Успех — в stdout:
`{"schema_version":1,"command":"…","data":…}`, с отступами, если stdout — терминал. Ошибка —
в stderr: `{"schema_version":1,"error":{"code":"…","message":"…","exit_code":N}}`.
`earmark help --json` выдаёт полную машиночитаемую таблицу команд.

| Команда | Что делает |
|---|---|
| `earmark status` | Состояние, текущая запись, ближайшая авто-запись, права, очередь, предупреждения. App не поднимает: вместо этого `"app_running": false` |
| `earmark start [--title T]` | Начать ручную запись. Идемпотентно: если запись идёт, вернёт её |
| `earmark stop` | Остановить и свести; отвечает, когда `audio.m4a` уже записан |
| `earmark upcoming [--hours 24]` | События, которые будут записаны |
| `earmark calendars` | Календари с `enabled`, аккаунтом и папкой |
| `earmark calendars enable <id>`, `earmark calendars disable <id>` | Включить или выключить авто-запись календаря |
| `earmark recordings [--since D] [--until D] [--calendar ID] [--status S] [--limit N]` | Записи, новые первыми. `D` — `YYYY-MM-DD` по местному времени или ISO 8601 |
| `earmark recording <id>` | `meta.json` и абсолютные пути файлов, которые уже есть |
| `earmark transcript <id> [--offset N] [--words N] [--format txt\|json]` | Транскрипт страницами по 200 слов (максимум 500) с `next_offset`; `json` отдаёт все сегменты сразу |
| `earmark transcribe <id> [--force]` | Поставить запись в очередь расшифровки app. `--force` — заново для расшифрованной или упавшей |
| `earmark transcribe <id> --now [--force]` | Расшифровать в этом процессе — так app запускает воркер |
| `earmark model status`, `earmark model download`, `earmark model import <path>` | Модель Whisper |
| `earmark config list`, `earmark config get <key>` | Настройки, читаются с диска |
| `earmark config set <key> <value>`, `earmark config reset <key>`, `earmark config reset --all` | Изменить настройки через app: с проверкой и сразу в силе |
| `earmark doctor [--audio-test]` | Проверить всё; код выхода 1, если что-то не готово |
| `earmark permissions request` | Попросить app показать системные запросы прав |
| `earmark mcp` | stdio MCP-сервер |
| `earmark help [--json]` | Таблица команд |

Командам, которым нужен app, — start, stop, upcoming, calendars, `config set` и `config reset`,
`transcribe` без `--now`, doctor и `permissions request` — CLI сам поднимает его через
`open -g -b com.konayre.earmark` и ждёт до 5 секунд. Остальные читают обычные файлы и работают
без app.

Коды выхода: 0 ok · 1 operation_failed · 2 not_found · 3 app_not_running · 4 permission_denied ·
64 invalid_arguments · 65 bad_data · 69 unavailable · 75 busy.

## Настройки

`~/Library/Application Support/earmark/config.json` пишет только app. Настройки меняйте через
`earmark config set`: значение проверяется и применяется сразу. Правка файла руками при
работающем app подхватится только после перезапуска.

| Ключ | Тип | По умолчанию | Примечание |
|---|---|---|---|
| `auto_record` | bool | `true` | Главный выключатель авто-записи |
| `lead_seconds` | int 0…3600 | `60` | За сколько до события начинать |
| `recordings_dir` | путь | `~/Earmark` | Должен быть доступен для записи; Desktop, Documents и Downloads не принимаются |
| `launch_at_login` | bool | `true` | Автозапуск через `SMAppService` |
| `calendars` | список id | `[]` | Включённые календари. Порядок — приоритет при одновременных событиях |
| `calendar.<id>.lead_seconds` | int | — | Своё `lead_seconds` для календаря |
| `calendar.<id>.folder` | строка | — | Имя папки вместо названия календаря |
| `stop.call_end_seconds` | int | `60` | Столько нет активности созвона → стоп (`call_ended`) |
| `stop.after_end_seconds` | int | `120` | Событие кончилось столько назад, оба канала молчат → стоп (`event_over`) |
| `stop.end_quiet_seconds` | int | `60` | Сколько оба канала должны молчать для `event_over` |
| `stop.silence_minutes` | int | `10` | Оба канала молчат столько → стоп (`silence`). Считается только после того, как созвон был виден: тишина до подключения опоздавших запись не останавливает |
| `stop.join_grace_minutes` | int | `10` | Созвона нет к старту + столько → стоп (`no_call`); если созвон появится до конца события, запись начнётся заново |
| `stop.max_minutes` | int | `300` | Жёсткий потолок, и для ручных записей тоже |
| `stop.min_keep_seconds` | int | `45` | Авто-записи короче удаляются |
| `audio.keep_raw_tracks` | bool | `false` | Не удалять `mic.caf` и `system.caf` после сведения |
| `transcription.enabled` | bool | `true` | Расшифровывать после каждой записи |
| `transcription.language` | строка | `auto` | Код языка Whisper (`en`, `ru`, …) или `auto` |
| `transcript.label_me` | строка | `Me` | Моя подпись в `transcript.txt` |
| `transcript.label_them` | строка | `Them` | Подпись собеседников в `transcript.txt` |

`EARMARK_HOME` переносит служебные файлы — конфиг, состояние, сокет и модели — в другой каталог:
пригодится для dev-сборки. App его тоже читает, поэтому запускайте его с тем же значением:
`open --env EARMARK_HOME="$EARMARK_HOME" -b com.konayre.earmark`. Путь держите коротким:
`$EARMARK_HOME/earmark.sock` должен уложиться в 103 байта — предел macOS для пути Unix-сокета,
иначе app не откроет сокет.

## Агенты

- **Claude Code** работает с CLI через skill. `make install-skill` делает симлинк
  `skills/earmark` в `~/.claude/skills` и, если каталог есть, в `~/.agents/skills` — общий
  каталог, который читают Codex и другие агенты (`~/.codex/skills` — только когда общего нет).
  Ссылки ведут в репозиторий, поэтому `git pull` обновляет и skill. Нужна копия, а не ссылка —
  из корня репозитория
  `npx --yes skills add . --skill earmark --global --agent claude-code --agent codex --agent universal -y`.
  Для запусков без человека разрешите CLI в `settings.json`: `"Bash(earmark:*)"`.
- **Codex** в своей песочнице закрывает шеллу Unix-сокеты, поэтому ходит в earmark через MCP —
  MCP-серверы он запускает вне песочницы:

  ```sh
  codex mcp add earmark -- ~/.local/bin/earmark mcp
  ```

  `stop_recording` отвечает только после финализации звука, а после долгого созвона это минуты;
  к тому же сервер обрабатывает вызовы по одному. По умолчанию Codex даёт MCP-tool 60 секунд,
  поэтому поднимите предел в `~/.codex/config.toml`, в таблице, которую создал `codex mcp add`:

  ```toml
  [mcp_servers.earmark]
  tool_timeout_sec = 300
  ```

- **Любой другой MCP-клиент**: `earmark mcp` по stdio. Сервер понимает и handshake
  `initialize`, и `server/discover` из MCP 2026-07-28.

Skill и инструкции MCP-сервера требуют от агента: начинать запись только по вашей явной просьбе,
никогда не удалять записи, брать id из списков и считать транскрипты приватными.

## Приватность и согласие

Запись других людей там, где живёте вы или они, может требовать их согласия. Прежде чем
полагаться на авто-запись, проверьте, какие правила действуют для вас, и предупредите
собеседников. earmark не прячется: значок в строке меню меняется на время записи, а macOS
показывает свой индикатор микрофона.

Всё остаётся на вашем Mac. Записи лежат в `~/Earmark` (права 0700) и никуда не выгружаются,
расшифровка идёт локально. Канал системного звука ловит всё, что играет Mac, кроме самого
earmark, — уведомления и музыку тоже.

## Если что-то не так

- Начните с `earmark doctor`. `earmark doctor --audio-test` вдобавок проигрывает короткий тихий
  тон 440 Гц и проверяет, что канал системного звука его слышит: без права канал пишет тишину без
  всякой ошибки, так что это единственная надёжная проверка.
- **Собеседников не слышно** или в `earmark status` есть `far_end_digital_silence`: права на
  системный звук нет или оно протухло. Сбросьте и выдайте заново:

  ```sh
  tccutil reset AudioCapture com.konayre.earmark
  earmark permissions request
  ```

  Так же работают `tccutil reset Microphone com.konayre.earmark` и
  `tccutil reset Calendar com.konayre.earmark`.
- **Права спрашиваются после каждой сборки**: сборка подписана ad-hoc, настройте `signing.local`.
- **`app_not_running`**: Earmark.app нет в `/Applications` или он не стартовал. `make install`,
  потом `open -b com.konayre.earmark`.
- **`permission_denied` на сокете** в песочнице агента вроде Codex: используйте `earmark mcp`.
- **Логи**: `/usr/bin/log stream --predicate 'subsystem == "com.konayre.earmark"'` (полный путь
  обязателен: в zsh голый `log` — встроенная команда шелла).
- **Удаление**: сначала `tccutil reset All com.konayre.earmark` (tccutil находит app через
  LaunchServices, поэтому пока app ещё установлен), потом `make uninstall`. Записи в `~/Earmark`
  остаются на месте.

## Лицензия

[MIT](LICENSE). Сторонний код и модели с их лицензиями перечислены в [NOTICE](NOTICE).

Zoom, Microsoft Teams, Google Meet и другие упомянутые приложения — товарные знаки своих
владельцев. earmark только распознаёт их процессы и никак с ними не связан.
