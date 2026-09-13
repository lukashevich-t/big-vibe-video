#!/usr/bin/env bash
# deploy.sh — sync sources to vps2, build image, (re)start container under systemd.
#
# Usage:
#   ./deploy.sh                 # normal deploy (rsync + build + restart)
#   ./deploy.sh --init          # first-time: install Docker + enable service
#   ./deploy.sh --no-service    # run container but don't touch systemd
#   ./deploy.sh --host HOST     # override SSH host alias
#   ./deploy.sh --rebuild       # force --no-cache docker build
#
# Defaults: host=vps2 port=48390 user=root remote_dir=/opt/big-vibe-video

set -euo pipefail

HOST="vps2"
USER_REMOTE="root"
PORT="48390"
REMOTE_DIR="/opt/big-vibe-video"
SERVICE_NAME="big-vibe-video"
IMAGE_NAME="big-vibe-video"
CONTAINER_NAME="big-vibe-video"
HOST_PORT="3000"
CONTAINER_PORT="3000"
INIT_MODE=0
TOUCH_SERVICE=1
REBUILD=0

usage() {
  sed -n '2,12p' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init)        INIT_MODE=1; shift ;;
    --no-service)  TOUCH_SERVICE=0; shift ;;
    --rebuild)     REBUILD=1; shift ;;
    --host)        HOST="${2:-}"; shift 2 ;;
    -h|--help)     usage ;;
    *)             echo "Unknown arg: $1"; usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; }

# Sanity checks
command -v rsync >/dev/null || { err "rsync not installed locally"; exit 1; }
command -v ssh   >/dev/null || { err "ssh not installed locally"; exit 1; }
[[ -f "$SCRIPT_DIR/Dockerfile"                       ]] || { err "Dockerfile missing in $SCRIPT_DIR"; exit 1; }
[[ -f "$SCRIPT_DIR/package.json"                     ]] || { err "package.json missing"; exit 1; }
[[ -f "$SCRIPT_DIR/systemd/${SERVICE_NAME}.service"  ]] || { err "systemd/${SERVICE_NAME}.service missing"; exit 1; }

SSH_TARGET="${USER_REMOTE}@${HOST}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -p "$PORT")

remote() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

# --- INIT MODE: prepare server (Docker, dirs) -----------------------------------
if [[ $INIT_MODE -eq 1 ]]; then
  log "INIT: checking server prerequisites"
  remote "mkdir -p '$REMOTE_DIR'"

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
  log "INIT: done"
fi

# --- SYNC SOURCES ----------------------------------------------------------------
log "Syncing sources to ${SSH_TARGET}:${REMOTE_DIR}"
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
  -e "ssh -p $PORT" \
  ./ "${SSH_TARGET}:${REMOTE_DIR}/"

# --- (RE)INSTALL SYSTEMD UNIT ---------------------------------------------------
# Always refresh the unit file from the synced copy so changes to the unit
# (e.g. port, image name) get applied on every deploy.
if [[ $TOUCH_SERVICE -eq 1 ]]; then
  log "Installing systemd unit /etc/systemd/system/${SERVICE_NAME}.service"
  remote "install -m 0644 '${REMOTE_DIR}/systemd/${SERVICE_NAME}.service' /etc/systemd/system/${SERVICE_NAME}.service"
  remote "systemctl daemon-reload"
fi

# --- BUILD IMAGE ON SERVER -------------------------------------------------------
BUILD_FLAGS=()
[[ $REBUILD -eq 1 ]] && BUILD_FLAGS+=(--no-cache)

log "Building image ${IMAGE_NAME}:latest on ${HOST}"
remote "cd '${REMOTE_DIR}' && docker build ${BUILD_FLAGS[*]} -t ${IMAGE_NAME}:latest ."

# --- RESTART CONTAINER -----------------------------------------------------------
log "Stopping previous container (if any)"
remote "docker rm -f ${CONTAINER_NAME} 2>/dev/null || true"

if [[ $TOUCH_SERVICE -eq 1 ]]; then
  log "Starting via systemd: ${SERVICE_NAME}.service"
  remote "systemctl reset-failed ${SERVICE_NAME}.service 2>/dev/null || true"
  remote "systemctl enable ${SERVICE_NAME}.service" 2>/dev/null || true
  remote "systemctl restart --no-block ${SERVICE_NAME}.service"
  # Wait for the service to reach 'active' (Type=oneshot+RemainAfterExit marks active
  # once ExecStart exits 0). Cap the wait so we never hang forever.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    state=$(remote "systemctl is-active ${SERVICE_NAME}.service 2>/dev/null" || true)
    if [[ "$state" == "active" ]]; then
      break
    fi
    sleep 1
  done
  remote "systemctl is-active ${SERVICE_NAME}.service" || true
  remote "docker ps --filter name=${CONTAINER_NAME} --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" || true
else
  log "Starting container directly (no systemd touch)"
  remote "docker run -d --name ${CONTAINER_NAME} --restart unless-stopped -p ${HOST_PORT}:${CONTAINER_PORT} ${IMAGE_NAME}:latest"
fi

# --- HEALTH CHECK ----------------------------------------------------------------
log "Health check: http://${HOST}:${HOST_PORT}/"
sleep 1
if remote "curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:${HOST_PORT}/" | grep -q '^200$'; then
  log "OK — service is responding on port ${HOST_PORT}"
else
  err "Service is NOT responding on port ${HOST_PORT}"
  err "--- container logs ---"
  remote "docker logs --tail=50 ${CONTAINER_NAME} 2>&1 || true"
  exit 1
fi

log "Deployed → http://${HOST}:${HOST_PORT}/"
