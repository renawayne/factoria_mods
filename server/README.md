# Factorio — Death_train

Docker-проект для приватного Factorio Space Age сервера. Пользовательские ZIP-моды и `mod-list.json` берутся из публичного GitHub-репозитория:

- Repository: `renawayne/factoria_mods`
- Branch: `main`
- Pack folder: `Death_train/mods`

## Что хранится в GitHub

В `Death_train/mods/` хранятся:
- ZIP-файлы только тех модов, которые нужно распространять через эту сборку (например, изменённый `train-interiors_1.0.10.zip`);
- `mod-list.json` — список включённых и выключенных модов для этой сборки.

Остальные ZIP-моды в GitHub добавлять не нужно. Они загружаются сервером с официального Factorio Mod Portal.

**Важно:** `mod-list.json` в GitHub является источником истины. При синхронизации сервер и Windows-клиент получают именно этот список. Изменяй его в клиентской папке Factorio, затем копируй в репозиторий и отправляй через Git.

## ZIP-формат

Архив должен быть обычным ZIP-модом Factorio и содержать ровно один `info.json`. Поддерживается как файл в корне архива, так и стандартная структура с папкой мода внутри ZIP:

```text
train-interiors_1.0.10.zip
└── train-interiors_1.0.10/
    └── info.json
```

В `info.json` обязательно должно быть корректное поле `name`.

## Развёртывание через Portainer

1. Portainer → Stacks → Add stack → Repository.
2. Repository URL: `https://github.com/renawayne/factoria_mods`
3. Branch: `main`
4. Compose path: `server/docker-compose.yml`
5. Включи сборку образа из Dockerfile, если Portainer предлагает такую настройку.
6. Задай переменные окружения из следующего раздела.
7. Deploy.

Compose-файл использует Dockerfile из папки `server/`. Данные Factorio сохраняются на хосте в `/opt/factorio-death-train`.

## Переменные окружения

Для автоматической загрузки официальных модов с Mod Portal задай в Portainer:

```env
UPDATE_MODS_ON_START=true
FACTORIO_USERNAME=твой_логин_factorio.com
FACTORIO_TOKEN=твой_токен_factorio.com
```

Также можно задать:

```env
ADMIN_LIST=PlayerOne,PlayerTwo
SERVER_PORT=34197
```

`FACTORIO_USERNAME` и `FACTORIO_TOKEN` — учётные данные Factorio.com, не GitHub. Не публикуй их и не помещай в репозиторий.

Серверный синхронизатор:
- при каждом старте скачивает пользовательские ZIP и `mod-list.json` из GitHub;
- проверяет ZIP и `info.json` до применения;
- меняет только моды, которыми управляет GitHub-синхронизация;
- сохраняет резервные копии старых ZIP, `mod-list.json` и последнего сейва;
- передаёт имена управляемых модов штатному запускателю через `UPDATE_IGNORE`, чтобы официальный обновлятор Factorio не заменил изменённые ZIP оригинальными;
- если GitHub недоступен, сохраняет уже установленный набор модов и продолжает запуск. Имена ранее установленных пользовательских модов остаются защищёнными от Mod Portal updater.

Если GitHub недоступен при самом первом запуске и моды ещё не установлены, синхронизатор не сможет получить пользовательские файлы. Повтори запуск после восстановления доступа.

## Настройки сервера

После первого запуска отредактируй:

`/opt/factorio-death-train/config/server-settings.json`

Рекомендуемые значения для приватного сервера:

```json
"visibility": {
  "public": false,
  "lan": false
},
"game_password": "ЗАДАЙ_СВОЙ_ПАРОЛЬ",
"max_players": 10,
"auto_pause": false,
"autosave_interval": 10,
"autosave_slots": 5
```

Не публикуй `server-settings.json`: в нём находится пароль сервера.

Администраторы задаются переменной `ADMIN_LIST`, например `PlayerOne,PlayerTwo`.

## Порты

Пробрось на роутере и разреши в firewall Ubuntu только UDP `34197` (или значение `SERVER_PORT`). RCON наружу не публикуется.

## Windows-клиент

Положи `UpdateFactorioMods.bat` и `UpdateFactorioMods.ps1` в одну папку и запусти BAT перед игрой.

Скрипт:
- скачивает пользовательские ZIP и `mod-list.json` из GitHub;
- не перезаписывает ZIP-файлы, которыми не управляет;
- обновляет только ZIP-файлы из GitHub-сборки;
- сохраняет резервные копии перед изменениями.

Официальные моды из Mod Portal клиент Factorio может загрузить штатно при подключении к серверу, если они доступны на Mod Portal.

## Бэкапы и логи

Серверные резервные копии синхронизации:

`/opt/factorio-death-train/backups/github-mod-sync/`

Логи:

```bash
docker logs -f factorio-death-train
```

Не удаляй `/opt/factorio-death-train` при обновлении контейнера: там находятся сейвы, конфигурация и резервные копии.

## Первый запуск

Для первичного теста лучше создать новый мир. Не переноси старый сейв, пока не убедишься, что сервер запускается и все версии модов совпадают. После успешной проверки можно остановить контейнер и перенести сейв в `/opt/factorio-death-train/saves/`.
