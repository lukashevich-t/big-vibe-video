#!/usr/bin/env bash
# deploy.sh — sync sources to vps2, build image, (re)start via docker compose.
#
# Usage:
#   ./deploy.sh                 # normal deploy (rsync + compose up -d --build)
#   ./deploy.sh --init          # first-time: install Docker on the server
#   ./deploy.sh --init-proxy    # first-time: bootstrap nginx-proxy + acme-companion
#                               #             in /opt/nginx-proxy/ on the server
#   ./deploy.sh --no-build      # pull existing image, don't rebuild
#   ./deploy.sh --host HOST     # override SSH host alias
#
# Defaults: host=vps2 port=48390 user=root remote_dir=/opt/big-vibe-video
#
# Architecture:
#   /opt/nginx-proxy/  — общий reverse-proxy (jwilder/nginx-proxy +
#                         nginxproxy/acme-companion), docker compose.
#   /opt/big-vibe-video/ — приложение, docker compose, отдельная сеть
#                          `nginx-proxy` (external), переменные
#                          VIRTUAL_HOST / LETSENCRYPT_* из .env.

set -euo pipefail

HOST="vps2"
USER_REMOTE="root"
PORT="48390"
APP_REMOTE_DIR="/opt/big-vibe-video"
PROXY_REMOTE_DIR="/opt/nginx-proxy"
PROXY_NETWORK="nginx-proxy"
SERVICE_NAME="app"               # имя сервиса внутри docker-compose.yml
IMAGE_NAME="big-vibe-video"
CONTAINER_NAME="big-vibe-video"
INIT_MODE=0
INIT_PROXY=0
DO_BUILD=1

usage() {
  sed -n '2,17p' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init)         INIT_MODE=1; shift ;;
    --init-proxy)   INIT_PROXY=1; shift ;;
    --no-build)     DO_BUILD=0; shift ;;
    --host)         HOST="${2:-}"; shift 2 ;;
    -h|--help)      usage ;;
    *)              echo "Unknown arg: $1"; usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; }

# Sanity checks
command -v rsync >/dev/null || { err "rsync not installed locally"; exit 1; }
command -v ssh   >/dev/null || { err "ssh not installed locally"; exit 1; }
[[ -f "$SCRIPT_DIR/Dockerfile"           ]] || { err "Dockerfile missing in $SCRIPT_DIR"; exit 1; }
[[ -f "$SCRIPT_DIR/package.json"         ]] || { err "package.json missing"; exit 1; }
[[ -f "$SCRIPT_DIR/docker-compose.yml"   ]] || { err "docker-compose.yml missing"; exit 1; }
[[ -f "$SCRIPT_DIR/.env" || -f "$SCRIPT_DIR/.env.example" ]] \
  || { err ".env (or .env.example) missing — copy from .env.example and edit"; exit 1; }

# Prefer local .env; fall back to .env.example (значения всё равно перепишутся на сервере).
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$SCRIPT_DIR/.env.example"

SSH_TARGET="${USER_REMOTE}@${HOST}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -p "$PORT")
remote() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

# --- INIT MODE: prepare server (Docker) ---------------------------------------
if [[ $INIT_MODE -eq 1 ]]; then
  log "INIT: checking server prerequisites"
  remote "mkdir -p '$APP_REMOTE_DIR' '$PROXY_REMOTE_DIR'"

  if ! remote "command -v docker" >/dev/null 2>&1; then
    log "Docker not found on $HOST — installing"
    remote 'bash -s' <<'INSTALL_DOCKER'
set -e
export DEBIAN_FRONTEND=noninteractive
ARCH=$(dpkg --print-architecture)
rm -f /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --batch --no-tty > /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
INSTALL_DOCKER
  else
    log "Docker already present"
  fi

  # Disable the legacy systemd unit (если он остался от предыдущей схемы).
  if remote "systemctl list-unit-files | grep -q '^${IMAGE_NAME}\.service'"; then
    log "Disabling legacy systemd unit ${IMAGE_NAME}.service"
    remote "systemctl stop ${IMAGE_NAME}.service 2>/dev/null || true"
    remote "systemctl disable ${IMAGE_NAME}.service 2>/dev/null || true"
    remote "rm -f /etc/systemd/system/${IMAGE_NAME}.service"
    remote "systemctl daemon-reload"
  fi

  # Stop legacy bare container, если остался.
  remote "docker rm -f ${CONTAINER_NAME} 2>/dev/null || true"

  log "INIT: done"
fi

# --- INIT PROXY MODE: поднять nginx-proxy в /opt/nginx-proxy -------------------
if [[ $INIT_PROXY -eq 1 ]]; then
  log "INIT-PROXY: bootstrapping nginx-proxy in ${PROXY_REMOTE_DIR}"
  remote "mkdir -p '$PROXY_REMOTE_DIR'"

  # Upload proxy stack files (они лежат рядом с deploy.sh).
  rsync -az \
    -e "ssh -p $PORT" \
    "$SCRIPT_DIR/proxy/docker-compose.yml" \
    "$SCRIPT_DIR/proxy/.env.example" \
    "${SSH_TARGET}:${PROXY_REMOTE_DIR}/"

  # .env — копия .env.example, если на сервере ещё нет своего.
  remote "[[ -f '${PROXY_REMOTE_DIR}/.env' ]] || cp '${PROXY_REMOTE_DIR}/.env.example' '${PROXY_REMOTE_DIR}/.env'"

  log "Bringing up nginx-proxy stack"
  remote "cd '${PROXY_REMOTE_DIR}' && docker compose pull --quiet"
  remote "cd '${PROXY_REMOTE_DIR}' && docker compose up -d --remove-orphans"

  # Ждём, пока nginx-proxy поднимется и начнёт слушать 80/443.
  for i in $(seq 1 30); do
    code=$(remote "curl -sS -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:80/ 2>/dev/null || true")
    if [[ "$code" =~ ^[0-9]{3}$ ]]; then
      log "nginx-proxy is listening on :80 (got ${code})"
      break
    fi
    sleep 1
  done

  log "INIT-PROXY: done"
fi

# --- Убедиться, что external network существует ------------------------------
# На случай если --init-proxy не запускали в этой сессии.
if ! remote "docker network inspect ${PROXY_NETWORK} >/dev/null 2>&1"; then
  err "External network '${PROXY_NETWORK}' does not exist"
  err "Run: ./deploy.sh --init-proxy"
  exit 1
fi

# --- SYNC PROXY STACK FILES (на обычном деплое тоже) ---------------------------
# Чтобы бампы версий proxy-стека подхватывались без --init-proxy,
# зальём актуальные proxy/compose + .env.example и применим.
if remote "[[ -d '${PROXY_REMOTE_DIR}' ]]"; then
  log "Syncing proxy stack to ${PROXY_REMOTE_DIR}"
  rsync -az \
    -e "ssh -p $PORT" \
    "$SCRIPT_DIR/proxy/docker-compose.yml" \
    "$SCRIPT_DIR/proxy/.env.example" \
    "${SSH_TARGET}:${PROXY_REMOTE_DIR}/"
  remote "[[ -f '${PROXY_REMOTE_DIR}/.env' ]] || cp '${PROXY_REMOTE_DIR}/.env.example' '${PROXY_REMOTE_DIR}/.env'"
  log "Applying proxy stack (pull + up -d)"
  remote "cd '${PROXY_REMOTE_DIR}' && docker compose pull --quiet"
  remote "cd '${PROXY_REMOTE_DIR}' && docker compose up -d --remove-orphans"
else
  log "Proxy stack not initialised on host — skipping (run --init-proxy to set up)"
fi

# --- SYNC SOURCES --------------------------------------------------------------
log "Syncing sources to ${SSH_TARGET}:${APP_REMOTE_DIR}"
rsync -az --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude '.vite' \
  --exclude 'dist' \
  --exclude '.ssh-mcp' \
  --exclude '.mcp.json' \
  --exclude '*.log' \
  --exclude '.DS_Store' \
  --exclude '.idea' \
  --exclude '.vscode' \
  --exclude 'deploy.sh' \
  --exclude 'proxy/' \
  --exclude '.env.example' \
  -e "ssh -p $PORT" \
  ./ "${SSH_TARGET}:${APP_REMOTE_DIR}/"

# .env не в гите, поэтому rsync его не зальёт — копируем отдельно
# (на сервере появится файл /opt/big-vibe-video/.env).
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  log "Uploading .env to ${APP_REMOTE_DIR}/.env"
  rsync -az -e "ssh -p $PORT" "$SCRIPT_DIR/.env" "${SSH_TARGET}:${APP_REMOTE_DIR}/.env"
else
  err ".env not found locally — copy from .env.example and edit before deploying"
  exit 1
fi

# --- BUILD + RESTART через docker compose -------------------------------------
BUILD_ARGS=()
COMPOSE_ARGS=(up -d --remove-orphans)
if [[ $DO_BUILD -eq 1 ]]; then
  BUILD_ARGS+=(--build)
fi

log "(Re)starting app via docker compose on ${HOST}"
remote "cd '${APP_REMOTE_DIR}' && docker compose ${COMPOSE_ARGS[*]} ${BUILD_ARGS[*]} ${SERVICE_NAME}"

# --- HEALTH CHECK --------------------------------------------------------------
# Внешний домен может ещё не отвечать (Let's Encrypt в процессе выпуска),
# поэтому проверяем и внутренний healthcheck, и доступность через прокси.
sleep 2

log "Health check (internal): http://127.0.0.1:3000/healthz"
if remote "docker inspect --format='{{.State.Health.Status}}' ${CONTAINER_NAME}" 2>/dev/null \
     | grep -q '^healthy$'; then
  log "OK — container is healthy"
else
  err "Container is NOT healthy yet"
  err "--- container logs ---"
  remote "docker logs --tail=50 ${CONTAINER_NAME} 2>&1 || true"
  exit 1
fi

VHOST=$(grep -E '^VIRTUAL_HOST=' "$ENV_FILE" | head -1 | cut -d= -f2-)
log "Waiting for https://${VHOST}/ to respond"
ok=0
for i in $(seq 1 30); do
  code=$(remote "curl -ksS -o /dev/null -m 5 -w '%{http_code}' https://${VHOST}/" 2>/dev/null || true)
  if [[ "$code" =~ ^2 ]]; then
    log "OK — https://${VHOST}/ → ${code}"
    ok=1
    break
  fi
  sleep 2
done

if [[ $ok -ne 1 ]]; then
  err "https://${VHOST}/ is not responding with 2xx yet"
  err "--- nginx-proxy logs (last 40 lines) ---"
  remote "docker logs --tail=40 nginx-proxy 2>&1 || true"
  err "--- acme-companion logs (last 40 lines) ---"
  remote "docker logs --tail=40 nginx-proxy-acme 2>&1 || true"
  err "--- app logs (last 40 lines) ---"
  remote "docker logs --tail=40 ${CONTAINER_NAME} 2>&1 || true"
  exit 1
fi

log "Deployed → https://${VHOST}/"
