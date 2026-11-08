# Factorio — Death_train

Docker-проект для приватного Factorio Space Age сервера с синхронизацией одного или нескольких пользовательских ZIP-модов из публичного GitHub.

## Репозиторий модов

- GitHub: `renawayne/factoria_mods`
- Branch: `main`
- Папка сборки: `Death_train/mods`

В `Death_train/mods/` помещаются только ZIP-файлы пользовательских модов. Имя ZIP должно быть стандартным для Factorio, а внутри архива на верхнем уровне должен лежать `info.json` с корректным полем `name`.

Пример:
```text
factoria_mods/
└── Death_train/
    └── mods/
        └── MyModifiedMod_1.0.0.zip
```

Обычные моды из Mod Portal в этот GitHub-каталог не помещаются.

## Что входит

- `Dockerfile` — образ на базе `factoriotools/factorio:stable`.
- `docker-compose.yml` — Stack для Portainer.
- `scripts/factorio-entrypoint.sh` — синхронизация перед штатным запуском Factorio.
- `scripts/sync-github-mods.sh` — скачивает ZIP-моды из GitHub, проверяет архивы и обновляет только файлы, которыми управляет этот скрипт.
- `UpdateFactorioMods.bat` + `UpdateFactorioMods.ps1` — обновление пользовательских ZIP-модов на Windows.

## Развёртывание через Portainer

Рекомендуемый вариант — сначала добавить эту папку `server/` в репозиторий `renawayne/factoria_mods`, затем в Portainer:

1. Stacks → Add stack → Repository.
2. Repository URL: `https://github.com/renawayne/factoria_mods`
3. Branch: `main`
4. Compose path: `server/docker-compose.yml`
5. Разрешить сборку образа из Dockerfile, если Portainer предлагает эту опцию.
6. Deploy.

Если проект хранится отдельно, скопируйте содержимое `server/` в Git-репозиторий, доступный Portainer, и укажите соответствующий Compose path.

Данные Factorio сохраняются на хосте в `/opt/factorio-death-train`.

## Важная настройка официальных модов

Dedicated server должен иметь файлы всех модов, необходимых для загрузки сохранения.

Для автоматического скачивания включённых модов с официального Factorio Mod Portal:

1. В Portainer добавьте переменные `UPDATE_MODS_ON_START=true`, `FACTORIO_USERNAME` и `FACTORIO_TOKEN`.
2. Перенесите актуальный `mod-list.json` из клиентской папки `%APPDATA%\Factorio\mods\mod-list.json` в `/opt/factorio-death-train/mods/mod-list.json`.
3. Убедитесь, что в `mod-list.json` включены необходимые моды.
4. GitHub-managed ZIP-моды синхронизатор добавит в список сам и автоматически добавит их имена в `UPDATE_IGNORE`, чтобы официальный updater не заменил изменённую версию.

`USERNAME` и `TOKEN` — учётные данные Factorio.com, не GitHub. Не публикуйте их и не помещайте в репозиторий.

Если `UPDATE_MODS_ON_START=false`, сервер не будет автоматически загружать отсутствующие моды с Mod Portal. Уже установленные ZIP-файлы останутся на месте.

## Настройки сервера

После первого запуска отредактируйте:

`/opt/factorio-death-train/config/server-settings.json`

Установите:
- `visibility.public`: `false`
- `visibility.lan`: `false`
- `game_password`: свой пароль
- `max_players`: нужное количество игроков
- `auto_pause`: `false`
- `autosave_interval`: `10`
- `autosave_slots`: `5`

Список администраторов можно задать в Portainer через переменную `ADMIN_LIST`, перечислив игровые имена через запятую, например `PlayerOne,PlayerTwo`. При каждом старте файл `/opt/factorio-death-train/config/server-adminlist.json` будет формироваться из этого значения.

Пароль и остальные игровые настройки задаются в `/opt/factorio-death-train/config/server-settings.json` после первого запуска:
- `visibility.public`: `false`
- `visibility.lan`: `false`
- `game_password`: свой пароль
- `max_players`: нужное количество игроков
- `auto_pause`: `false`
- `autosave_interval`: `10`
- `autosave_slots`: `5`

## Порты

Открыть и пробросить на Ubuntu-сервер только UDP `34197` (или значение `SERVER_PORT`).

RCON не публикуется.

## Windows-клиент

Положите рядом:
- `UpdateFactorioMods.bat`
- `UpdateFactorioMods.ps1`

Запустите BAT перед игрой. Скрипт обновляет только ZIP-файлы, управляемые GitHub-синхронизацией, и соответствующие записи в `mod-list.json`. Остальные моды и настройки не удаляются.

Папка модов по умолчанию:
`%APPDATA%\Factorio\mods`

## Поведение синхронизатора

- Проверка GitHub выполняется при каждом старте/перезапуске контейнера.
- Все ZIP скачиваются во временную папку и проверяются до применения.
- Существующие ZIP, не принадлежащие синхронизатору, не перезаписываются.
- Удаляются только ZIP, которые были ранее зарегистрированы как управляемые этим синхронизатором.
- `mod-list.json` обновляется точечно, остальные записи сохраняются.
- При изменении создаётся резервная копия старых управляемых ZIP, `mod-list.json` и самого свежего сейва.
- Хранятся последние три резервные копии синхронизации.
- Если GitHub временно недоступен, ZIP повреждён или обнаружен конфликт имён, синхронизатор оставляет последнюю установленную сборку и продолжает запуск сервера. Это не даёт кратковременному сбою GitHub выключить игровой сервер.

Резервная копия не является автоматическим откатом после ошибки загрузки сохранения. Перед обновлением крупных или важных миров рекомендуется иметь отдельные регулярные бэкапы всей `/opt/factorio-death-train`.

## Первый запуск и перенос сейва

Для первого теста не переносите старый сейв. Запустите чистый сервер, проверьте соединение и совместимость модов. После этого остановите контейнер и перенесите сохранение и нужные конфиги в соответствующие папки `/opt/factorio-death-train`.

`GENERATE_NEW_SAVE=true` создаёт новый мир только если подходящего сохранения ещё нет. Не удаляйте папку данных при обновлении контейнера.

## Логи

```bash
docker logs -f factorio-death-train
```

Папка резервных копий:
`/opt/factorio-death-train/backups/github-mod-sync/`
