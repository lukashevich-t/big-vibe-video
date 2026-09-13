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

На сервере работают **два независимых docker compose-стека**, объединённых
общей внешней сетью `nginx-proxy`:

```
Интернет ──► nginx-proxy (80/443, сертификат Let's Encrypt)
                  │  docker network: nginx-proxy
                  ▼
            big-vibe-video  ────► nginx внутри контейнера :3000
```

* **Приложение:** Vue 3 SPA (`src/`, `index.html`, сборка через Vite),
  multi-stage Dockerfile (node:20-alpine → nginx:1.27-alpine на 3000).
* **docker-compose.yml** — описывает только приложение. Порт на хост **не
  публикуется**, наружу смотрит исключительно nginx-proxy. Конфиг
  читает переменные из локального `.env` (`VIRTUAL_HOST`,
  `LETSENCRYPT_HOST`, `LETSENCRYPT_EMAIL`).
* **proxy/docker-compose.yml** — описывает `nginxproxy/nginx-proxy:1.1.0`
  и `nginxproxy/acme-companion:2.4.0`. Поднимается отдельно в
  `/opt/nginx-proxy/`.
* **Хост:** `vps2:48390` (root, ключ `~/.ssh/id_ed25519_test`, есть в
  `~/.ssh/config`).
* **Домен:** `bigvibecourse.freedynamicdns.net` → `132.243.214.223` (A-запись
  уже настроена).

## Скрипт деплоя — `deploy.sh`

```bash
./deploy.sh                 # обычный деплой (rsync + compose up -d --build)
./deploy.sh --init          # первый запуск: установит Docker на сервере
./deploy.sh --init-proxy    # поднять nginx-proxy + acme-companion в /opt/nginx-proxy/
./deploy.sh --no-build      # поднять без пересборки образа
./deploy.sh --host HOST     # переопределить SSH-хост (по умолчанию vps2)
```

`deploy.sh` идемпотентен: каждый запуск заново синхронизирует исходники,
пересобирает образ, и перезапускает стек через `docker compose up -d`.

## Первый запуск (полная последовательность)

```bash
cp .env.example .env       # отредактируйте под свой домен/email
./deploy.sh --init         # установит Docker, отключит старый systemd-юнит
./deploy.sh --init-proxy   # поднимет nginx-proxy + acme-companion
./deploy.sh                # соберёт образ и задеплоит приложение
```

После этого:

* `https://bigvibecourse.freedynamicdns.net/` отвечает валидным
  сертификатом Let's Encrypt.
* Сертификат обновляется автоматически (acme-companion следит за
  истечением).

## Ежедневный деплой

```bash
# поправил код → коммитишь →
./deploy.sh
```

Скрипт сделает: rsync → `docker compose build` → `docker compose up -d`.

## Артефакты на сервере

| Что | Где |
|-----|-----|
| Исходники приложения | `/opt/big-vibe-video/` |
| Стек приложения (compose) | `/opt/big-vibe-video/docker-compose.yml` |
| `.env` приложения | `/opt/big-vibe-video/.env` |
| Стек прокси (compose) | `/opt/nginx-proxy/docker-compose.yml` |
| `.env` прокси | `/opt/nginx-proxy/.env` |
| Сертификаты | volume `nginx-proxy_certs` (named) |
| Кэш acme.sh | volume `nginx-proxy_acme` (named) |
| Внешняя сеть | `nginx-proxy` (bridge) |
| Логи прокси | `docker logs nginx-proxy` |
| Логи acme-companion | `docker logs nginx-proxy-acme` |
| Логи приложения | `docker logs big-vibe-video` |
| Health приложения | `http://127.0.0.1:3000/healthz` (внутри контейнера) |

## Диагностика

```bash
# стеки и сеть
ssh vps2 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
ssh vps2 'docker network inspect nginx-proxy --format "{{range .Containers}}{{.Name}} {{end}}"'

# логи прокси / acme / приложения
ssh vps2 'docker logs --tail=100 nginx-proxy'
ssh vps2 'docker logs --tail=100 nginx-proxy-acme'
ssh vps2 'docker logs --tail=100 big-vibe-video'

# проверка сертификата
ssh vps2 'docker exec nginx-proxy ls /etc/nginx/certs'
curl -vI https://bigvibecourse.freedynamicdns.net/

# ручной рестарт
ssh vps2 'cd /opt/big-vibe-video && docker compose restart'
ssh vps2 'cd /opt/nginx-proxy   && docker compose restart'
```

## Как работает `VIRTUAL_HOST`

`nginx-proxy` слушает docker socket, видит контейнеры с переменной
окружения `VIRTUAL_HOST=<домен>` и автоматически проксирует запросы на
порт этого контейнера. `acme-companion` отдельно видит
`LETSENCRYPT_HOST` / `LETSENCRYPT_EMAIL` и запрашивает/обновляет
сертификат через ACME http-01 challenge (порт 80). Дополнительная
настройка nginx не нужна — конфиг генерируется при старте контейнеров.

## Миграция со старой схемы (systemd + bare docker run)

Старая версия использовала `systemd/big-vibe-video.service` и запускала
контейнер через `docker run -d ... -p 3000:3000`. Эта схема:

* конфликтовала с любым другим сервисом на 80/443;
* не умела выпускать сертификаты;
* не позволяла добавить второй сайт без правки systemd-юнита.

`deploy.sh --init` теперь отключает старый systemd-юнит и удаляет
голый контейнер, поэтому миграция прозрачна.

## Что нужно для деплоя локально

* `ssh` + `rsync` (в репо — `apt install rsync` / `brew install rsync`).
* SSH-ключ `~/.ssh/id_ed25519_test` (либо правьте `deploy.sh` `--host` и
  `PORT`/`USER_REMOTE`).
* Запись в `~/.ssh/config` (`Host vps2`, `Port 48390`, `User root`,
  `IdentityFile ~/.ssh/id_ed25519_test`).
* Локально должен существовать `.env` со значениями `VIRTUAL_HOST`,
  `LETSENCRYPT_HOST`, `LETSENCRYPT_EMAIL` (рядом с `docker-compose.yml`).
