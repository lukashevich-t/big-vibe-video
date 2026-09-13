# SSH MCP сервер для удалённого доступа

Проект подключён к MCP-серверу `ssh-mcp` (tufantunc, v2.8.1) для выполнения
команд на удалённом сервере `vps2:48390` под `root` с аутентификацией по
ключу `~/.ssh/id_ed25519_test` (ed25519).

## Структура

```
.mcp.json                  # подключение в pi (pi-mcp-adapter)
.ssh-mcp/
└── config.toml            # 0600 — профили SSH-серверов
```

## `.mcp.json`

```json
{
  "mcpServers": {
    "ssh-vps2": {
      "command": "npx",
      "args": [
        "-y",
        "ssh-mcp",
        "--config=${PWD}/.ssh-mcp/config.toml"
      ],
      "env": { "SSH_AUTH_SOCK": "${SSH_AUTH_SOCK}" },
      "directTools": true,
      "lifecycle": "lazy",
      "idleTimeout": 10
    }
  }
}
```

`${PWD}` подставляется интерполяцией pi — корректно резолвится в директорию
проекта, если pi запущен из неё. `${SSH_AUTH_SOCK}` сейчас не используется
(`auth = "key"` в `config.toml` берёт путь к ключу напрямую), но
оставлен в `env` на случай отката к `auth = "agent"`.

## `ssh-mcp.config.toml`

```toml
[defaults]
defaultProfile = "vps2"

[[profiles]]
name = "vps2"
host = "vps2"
user = "root"
port = 48390
auth = "key"
keyRef = "~/.ssh/id_ed25519_test"
```

TOML-схема строгая: `defaultProfile` лежит под `[defaults]`, профили —
**массив** `[[profiles]]` (не map). Для `auth = "key"` обязательно поле
`keyRef` с путём к приватному ключу (поддерживается `~`). CLI-режим без
явного `--key` ставит `auth = "password"` по умолчанию и тогда
провалидится на отсутствующем `SSH_MCP_PASSWORD`.

## Аутентификация

* ed25519-ключ `~/.ssh/id_ed25519_test`, публичная часть добавлена в
  `authorized_keys` на `vps2`.
* Секретный ключ — обычный файл на диске (passphrase при генерации не
  задавалась, иначе ssh-mcp зависнет на интерактивном prompt).
* `auth = "key"` + `keyRef` — ssh-mcp через ssh2-библиотеку читает файл
  и использует для каждого SSH-соединения.
* Никакого интерактива: ни тапов, ни ввода passphrase — каждый вызов
  чисто сетевой + handshake.

### Латентность

* **Первый запуск после простоя >`idleTimeout` (10 мин)**: новый TCP+SSH
  handshake, ~1-2с. Никаких тапов.
* **Повторные команды в одной MCP-сессии**: ~200мс, соединение
  переиспользуется из пула ssh-mcp.
* **После простоя >`idleTimeout` (10 мин)**: MCP-сервер закроет idle-SSH,
  следующая команда снова требует новый handshake.

### Бенчмарк (3 команды подряд)

Измерено с **YubiKey+agent** (`auth = "agent"`). С переходом на
`auth = "key"` тапы ушли — `run-command` #1 ожидается ближе к warm-цифрам,
точных замеров нет.

| Этап | cold | warm |
|------|------|------|
| MCP handshake | 1.13с | 1.14с |
| `run-command` #1 | 5.08с | 2.26с |
| `run-command` #2 | 0.26с | 0.21с |
| `run-command` #3 | 0.22с | 0.22с |
| **Итого** | **6.77с** | **3.94с** |

## Доступные инструменты

После `/reload` в pi:

| Tool | Назначение |
|------|------------|
| `run-command` | произвольная команда |
| `read-command` | read-only из allowlist |
| `privileged-command` | с sudo |
| `list-connections` | список профилей |
| `list-sessions` | активные сессии профиля |
| `open-session` / `close-session` | stateful-shell (`type=interactive` или `background`) |
| `read-session-output` | чтение вывода background-сессии |
| `signal-process` | послать сигнал процессу по PID |
| `sftp-upload` / `sftp-download` | передача файлов |

## Грабли, на которые наступили

### 1. ssh-mcp CLI — баг с разделителем

`--config <path>` (через пробел) парсер **не понимает**, нужен только
`--config=<path>` (через `=`). Это артефакт собственного парсера аргументов
ssh-mcp, и приходится держать флаг одной строкой в JSON-массиве:

```json
"args": ["-y", "ssh-mcp", "--config=${PWD}/.ssh-mcp/config.toml"]
```

### 2. Жёсткие требования к правам

ssh-mcp требует:

* файл конфига — `0600`
* директория конфига — `0700`

Если родительская директория шире (типичный `0755` для домашней или
проектной папки) — сервер стартует с ошибкой. Поэтому конфиг лежит в
**отдельной поддиректории** `.ssh-mcp/` с `chmod 700`, а не рядом с
`.mcp.json`.

### 3. TOML-схема

Не очевидно, что профили — массив, а не именованная карта. И что
`defaultProfile` вложен в `[defaults]`, а не на верхнем уровне. Неверная
схема валится на старте сервера, инструменты не появляются.

### 4. `${workspaceFolder}` — не переменная pi

VS Code-переменные (`workspaceFolder` и т.п.) pi не знает. Из доступных —
только `${ENV_VAR}`. Для проекта используем `${PWD}`.

### 5. npx ssh-mcp требует нативной сборки ssh2

При первом `npx -y ssh-mcp` пакету нужно скомпилировать нативные модули
ssh2 (gpg-agent-aware крипта). На холодном кэше — 2-3 минуты, на тёплом —
секунды. Это однократная плата.

## Альтернативы, которые не подошли

| Сервер | Причина отказа |
|--------|----------------|
| `@fangjunjie/ssh-mcp-server` | Тот же функционал, но per-call оверхед ~20с. Суммарно 70+ секунд на 3 команды. Возможно, из-за status-коллектора. |
| `mcp-server-ssh` (npm) | Не поддерживает auth через ssh-agent — только `password`, `privateKey` (плоский текст), `privateKeyPath` (файл). Сейчас бы подошёл (`auth = "key"` + `keyRef` даёт тот же эффект, что `privateKeyPath`), но привязки к YubiKey уже нет. |
| `tufantunc/ssh-mcp` (другой пакет) | То же, что используем, но без agent auth через env — требовался TOML-конфиг. |

## Что бы я попробовал дальше

* Положить ключ в `~/.ssh/config` с `Host vps2` и пробросом
  `IdentityFile`, чтобы pi/tools цеплялись без явного `keyRef`.
* Поднять `idleTimeout` или убрать `lifecycle: lazy`, чтобы в рамках
  активной pi-сессии держать SSH-соединение живым подольше.
* Добавить второй профиль в `config.toml` (например, `vps2-staging`),
  чтобы можно было выбирать через `profile` параметр в вызове.

---

# Деплой

## Архитектура

* **Приложение:** Vue 3 SPA (`src/`, `index.html`, сборка через Vite).
* **Dockerfile:** multi-stage — `node:20-alpine` (сборка) → `nginx:1.27-alpine` (раздача `dist/` на 3000).
* **Systemd-юнит:** `systemd/big-vibe-video.service` — `Type=oneshot RemainAfterExit=yes`,
  `ExecStart=docker run -d …`, автозапуск (`WantedBy=multi-user.target`).
* **Хост:** `vps2:48390` (root, ключ `~/.ssh/id_ed25519_test`, уже в `~/.ssh/config`).
* **Путь на сервере:** `/opt/big-vibe-video/`.

## Скрипт деплоя — `deploy.sh`

```bash
./deploy.sh                # обычный деплой (rsync + build + restart)
./deploy.sh --init         # первый запуск: установит Docker на сервере, если его нет
./deploy.sh --rebuild      # форсировать docker build --no-cache
./deploy.sh --no-service   # запустить контейнер вручную, не трогая systemd
./deploy.sh --host HOST    # переопределить SSH-хост (по умолчанию vps2)
```

`deploy.sh` идемпотентен: каждый запуск заново синхронизирует исходники,
пересобирает образ, переустанавливает systemd-юнит из `systemd/` и
перезапускает контейнер.

## Первый запуск

```bash
./deploy.sh --init         # установит Docker, скопирует systemd-юнит
./deploy.sh                # зальёт исходники, соберёт образ, стартует сервис
```

После этого приложение слушает `http://vps2:3000/`.

## Ежедневный деплой

```bash
# поправил код → коммитишь → пушишь (по желанию) →
./deploy.sh
```

Скрипт сделает: rsync → `docker build` → `systemctl restart`.

## Артефакты на сервере

| Что | Где |
|-----|-----|
| Исходники | `/opt/big-vibe-video/` |
| Docker-образ | `big-vibe-video:latest` |
| Контейнер | `big-vibe-video` (порт 3000) |
| systemd-юнит | `/etc/systemd/system/big-vibe-video.service` |
| Логи контейнера | `docker logs big-vibe-video` |
| Логи systemd | `journalctl -u big-vibe-video.service` |
| Health | `http://127.0.0.1:3000/healthz` |

## Диагностика

```bash
# статус
ssh vps2 'systemctl status big-vibe-video.service'
ssh vps2 'docker ps --filter name=big-vibe-video'

# логи
ssh vps2 'docker logs --tail=100 big-vibe-video'
ssh vps2 'journalctl -u big-vibe-video.service -n 100 --no-pager'

# ручной рестарт
ssh vps2 'systemctl restart big-vibe-video.service'
```

## Что нужно для деплоя локально

* `ssh` + `rsync` (в репо — `apt install rsync` / `brew install rsync`).
* SSH-ключ `~/.ssh/id_ed25519_test` (либо правьте `deploy.sh` `--host` и `PORT`/`USER_REMOTE`).
* Запись в `~/.ssh/config` (`Host vps2`, `Port 48390`, `User root`, `IdentityFile ~/.ssh/id_ed25519_test`) — уже есть.
