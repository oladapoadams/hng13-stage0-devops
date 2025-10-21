#!/usr/bin/env bash
# deploy.sh — Automated deployment for hng13-stage0-devops
# Author: Odebowale Oladapo Ayodele
# Usage: ./deploy.sh            # interactive
#        ./deploy.sh --cleanup  # remove deployed resources on remote
#
# Exit codes:
#  10 = missing required input
#  20 = repo clone/fetch failure
#  30 = no dockerfile/docker-compose found
#  40 = ssh connectivity failure
#  50 = remote prep failure
#  60 = transfer failure
#  70 = remote deploy failure

set -o errexit
set -o nounset
set -o pipefail

# -------------------------
# Logging setup
# -------------------------
TIMESTAMP() { date +"%Y%m%d_%H%M%S"; }
LOGFILE="deploy_$(TIMESTAMP).log"
# All stdout/stderr to logfile and to console
exec > >(tee -a "$LOGFILE") 2>&1

info()  { printf "[%s] INFO: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf "[%s] WARN: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Trap and cleanup
trap_on_error() {
  error "Script failed at line $1. See $LOGFILE"
  exit 1
}
trap 'trap_on_error $LINENO' ERR
trap 'info "Script interrupted."; exit 1' INT TERM

# -------------------------
# Helper functions
# -------------------------
is_valid_repo_url() {
  case "$1" in
    https://*github.com/*/*.git|https://*github.com/*/*|git@github.com:*/*.git) return 0 ;;
    *) return 1 ;;
  esac
}

mask() {
  # mask token for logs, keep first 3/last 3 visible if long
  local s="$1"
  if [ -z "$s" ]; then
    printf "(none)"
    return
  fi
  if [ "${#s}" -le 6 ]; then
    printf "***"
  else
    printf "%s***%s" "${s:0:3}" "${s: -3}"
  fi
}

to_forward_slash() {
  # convert windows backslashes to forward slashes
  printf '%s' "${1//\\//}"
}

# -------------------------
# Parse flags
# -------------------------
CLEAN=false
if [ "${#:-0}" -ge 1 ]; then
  for arg in "$@"; do
    case "$arg" in
      --cleanup) CLEAN=true ;;
      *) ;; 
    esac
  done
fi

info "=== Deploy script started ==="

# -------------------------
# 1. Collect parameters
# -------------------------
# If you want non-interactive defaults, update these variables before running.
read_input() {
  # interactive prompt helper: usage read_input VAR "prompt" [silent]
  local __var="$1"; shift
  local prompt_text="$1"; shift
  local silent="${1:-false}"
  if [ "$silent" = "true" ]; then
    printf "%s: " "$prompt_text"
    stty -echo
    IFS= read -r val || true
    stty echo
    printf "\n"
  else
    printf "%s: " "$prompt_text"
    IFS= read -r val || true
  fi
  eval "$__var=\"\$val\""
}

# If you prefer to set defaults non-interactively, uncomment & set them:
# REPO_URL="https://github.com/oladapoadams/hng13-stage0-devops"
# PAT=""
# BRANCH="main"
# SSH_USER="ubuntu"
# SERVER_IP="16.171.14.14"
# SSH_KEY="/c/Users/HP OMEN/Downloads/HNG-2.pem"
# APP_PORT="80"

# Collect only if not already set
if [ -z "${REPO_URL:-}" ]; then
  read_input REPO_URL "Git repository URL (HTTPS or SSH)"
fi
if [ -z "${PAT:-}" ]; then
  read_input PAT "Personal Access Token (PAT) (leave blank to use SSH auth)" true
fi
if [ -z "${BRANCH:-}" ]; then
  read_input BRANCH "Branch name (default: main)"
  BRANCH=${BRANCH:-main}
fi
if [ -z "${SSH_USER:-}" ]; then
  read_input SSH_USER "Remote server SSH username (e.g., ubuntu)"
fi
if [ -z "${SERVER_IP:-}" ]; then
  read_input SERVER_IP "Remote server IP or hostname"
fi
if [ -z "${SSH_KEY:-}" ]; then
  read_input SSH_KEY "SSH private key path (full path). Use /c/... for Git Bash on Windows"
  SSH_KEY=$(to_forward_slash "$SSH_KEY")
fi
if [ -z "${APP_PORT:-}" ]; then
  read_input APP_PORT "Application internal container port (e.g., 80 or 3000)"
fi

# Validate required
if [ -z "$REPO_URL" ] || [ -z "$SSH_USER" ] || [ -z "$SERVER_IP" ] || [ -z "$SSH_KEY" ] || [ -z "$APP_PORT" ]; then
  error "Missing required input. Aborting."
  exit 10
fi

# Validate repo URL
if ! is_valid_repo_url "$REPO_URL"; then
  warn "Repo URL doesn't look like a standard GitHub URL; continuing but double-check it."
fi

# Validate SSH key exists locally
if [ ! -f "$SSH_KEY" ]; then
  error "SSH key not found at path: $SSH_KEY"
  exit 10
fi
info "Using SSH key: $SSH_KEY"

info "Input summary:
  REPO_URL: $REPO_URL
  BRANCH: $BRANCH
  SSH_USER: $SSH_USER
  SERVER_IP: $SERVER_IP
  SSH_KEY: $SSH_KEY
  APP_PORT: $APP_PORT
  PAT: $(mask "$PAT")
"

# -------------------------
# 2. Clone or update repo locally
# -------------------------
REPO_NAME=$(basename -s .git "$REPO_URL")
if [ -d "$REPO_NAME" ]; then
  info "Repository '$REPO_NAME' exists locally. Fetching latest for branch $BRANCH..."
  (cd "$REPO_NAME" && git fetch --all --prune && git checkout "$BRANCH" && git reset --hard "origin/$BRANCH") || {
    error "Failed to update repository."
    exit 20
  }
else
  info "Cloning repository '$REPO_NAME'..."
  if [ -n "$PAT" ]; then
    # if REPO_URL is like https://github.com/owner/repo.git -> insert token
    auth_url="$REPO_URL"
    # strip leading https:// if present
    if printf "%s" "$REPO_URL" | grep -q '^https://'; then
      auth_url="https://${PAT}@${REPO_URL#https://}"
    fi
    git clone -b "$BRANCH" "$auth_url" || { error "Git clone failed"; exit 20; }
    # remove PAT from git config/remote URL locally
    (cd "$REPO_NAME" && git remote set-url origin "$REPO_URL")
  else
    git clone -b "$BRANCH" "$REPO_URL" || { error "Git clone failed"; exit 20; }
  fi
fi

# -------------------------
# 3. cd into dir & validate Docker files
# -------------------------
cd "$REPO_NAME" || { error "Failed to change into repo dir"; exit 20; }
if [ -f "Dockerfile" ]; then
  info "Found Dockerfile."
elif [ -f "docker-compose.yml" ]; then
  info "Found docker-compose.yml."
else
  error "No Dockerfile or docker-compose.yml found in repo root."
  exit 30
fi

# -------------------------
# 4. SSH connectivity check
# -------------------------
SSH_OPTS="-i \"$SSH_KEY\" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
info "Testing SSH connection to $SSH_USER@$SERVER_IP"
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo SSH_OK" >/dev/null 2>&1; then
  warn "SSH connectivity check failed. Trying interactive SSH to accept host key..."
  # try interactive once to add known_hosts (useful first-run)
  if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=ask "$SSH_USER@$SERVER_IP" "echo SSH_INTERACTIVE_OK"; then
    error "SSH interactive/connect failed. Fix connectivity and try again."
    exit 40
  fi
else
  info "SSH connectivity OK."
fi

if [ "$CLEAN" = "true" ]; then
  info "Running cleanup on remote host..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<'REMOTE_CLEAN'
set -e
APP_NAME='hng13-stage0-devops'
sudo docker stop "$APP_NAME" || true
sudo docker rm "$APP_NAME" || true
sudo rm -f /etc/nginx/sites-enabled/"$APP_NAME".conf /etc/nginx/sites-available/"$APP_NAME".conf || true
sudo nginx -t && sudo systemctl reload nginx || true
echo "CLEANUP_DONE"
REMOTE_CLEAN
  info "Remote cleanup completed."
  exit 0
fi

# -------------------------
# 5. Prepare remote environment (install docker, docker-compose, nginx)
# -------------------------
info "Preparing remote environment (apt update, install docker, docker-compose, nginx)..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<'REMOTE_PREP'
set -e
# idempotent install
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing docker..."
  sudo apt-get update -y
  sudo apt-get install -y docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
fi

if ! command -v docker-compose >/dev/null 2>&1; then
  echo "Installing docker-compose..."
  sudo apt-get install -y docker-compose-plugin || true
fi

if ! command -v nginx >/dev/null 2>&1; then
  echo "Installing nginx..."
  sudo apt-get install -y nginx
  sudo systemctl enable nginx
  sudo systemctl start nginx
fi

# add user to docker group if not already
if ! groups "$USER" | grep -q '\bdocker\b'; then
  sudo usermod -aG docker "$USER" || true
fi

# show versions
docker --version || true
docker compose version || true
nginx -v || true
REMOTE_PREP

info "Remote environment prepared."

# -------------------------
# 6. Deploy application: copy files and run container
# -------------------------
# Use rsync if available for safe and idempotent sync
info "Transferring project to remote host..."
if command -v rsync >/dev/null 2>&1; then
  RSYNC_OPTS="-az --delete --exclude='.git' --exclude='$LOGFILE'"
  rsync -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" $RSYNC_OPTS ./ "$SSH_USER@$SERVER_IP:/home/$SSH_USER/$REPO_NAME" || {
    error "rsync transfer failed"; exit 60
  }
else
  scp -r -i "$SSH_KEY" -o StrictHostKeyChecking=no . "$SSH_USER@$SERVER_IP:/home/$SSH_USER/$REPO_NAME" || {
    error "scp transfer failed"; exit 60
  }
fi
info "Project files transferred."

info "Building and running container on remote host..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<REMOTE_DEPLOY
set -e
APP_NAME="$REPO_NAME"
cd /home/$SSH_USER/\$APP_NAME

# Build (idempotent: --no-cache optional)
sudo docker build -t \$APP_NAME .

# Stop & remove previous container (if any)
sudo docker stop \$APP_NAME || true
sudo docker rm \$APP_NAME || true

# Run container mapping internal app port to host (we will proxy via nginx later)
# Run detached; map container port $APP_PORT to same port on host (for health checks)
sudo docker run -d --restart unless-stopped -p $APP_PORT:$APP_PORT --name \$APP_NAME \$APP_NAME
REMOTE_DEPLOY

info "Container build & run completed."

# -------------------------
# 7. Configure Nginx reverse proxy
# -------------------------
NGINX_CONF="/etc/nginx/sites-available/${REPO_NAME}.conf"
info "Configuring nginx reverse proxy (80 -> container:$APP_PORT)..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" sudo bash <<REMOTE_NGINX
set -e
APP_NAME="$REPO_NAME"
NGINX_CONF="$NGINX_CONF"

cat > "\$NGINX_CONF" <<'NGINX_EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
NGINX_EOF

ln -sf "\$NGINX_CONF" /etc/nginx/sites-enabled/${REPO_NAME}.conf
nginx -t
systemctl reload nginx
REMOTE_NGINX

info "Nginx configured & reloaded."

# -------------------------
# 8. Validate deployment
# -------------------------
info "Validating deployment on remote host..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<'REMOTE_VALIDATE'
set -e
APP_NAME="'"$REPO_NAME"'"
# Docker service
if ! systemctl is-active --quiet docker; then
  echo "ERROR: docker service not active"
  exit 1
fi

# Check container
if ! sudo docker ps --filter "name=$REPO_NAME" --format '{{.Names}}' | grep -q "$REPO_NAME"; then
  echo "ERROR: target container not running"
  exit 1
fi

# Curl local host through nginx
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/)
echo "HTTP_STATUS=\$HTTP_STATUS"
if [ "\$HTTP_STATUS" -ge 200 ] && [ "\$HTTP_STATUS" -lt 400 ]; then
  echo "OK"
else
  echo "ERROR: nginx returned HTTP \$HTTP_STATUS"
  exit 1
fi
REMOTE_VALIDATE

info "Validation completed. App should be available at: http://$SERVER_IP"

info "=== Deploy script finished successfully ==="
exit 0
