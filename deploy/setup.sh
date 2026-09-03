#!/usr/bin/env bash
#
# Deploys a single Frappe bench hosting three sites: ERPNext, CRM, Helpdesk.
#
# Two targets, selected by ENVIRONMENT in deploy/.env:
#   dev  -> host arch (*.localhost sites, no proxy, deploy/docker-compose.local.yaml)
#   prod -> host arch (real subdomains <app>.<DOMAIN>, deploy/docker-compose.yaml + Caddy)
#
# Usage:
#   1. cp deploy/.env.example deploy/.env  (set DB_PASSWORD, ADMIN_PASSWORD, ENVIRONMENT, DOMAIN)
#   2. bash deploy/setup.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root

PROJECT=frappe
ENV_FILE=deploy/.env

# Load config (image name/tag, environment, domain, passwords).
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

ENVIRONMENT="${ENVIRONMENT:-dev}"
DOMAIN="${DOMAIN:-requrv.io}"
IMAGE="${CUSTOM_IMAGE:-frappe-requrv}:${CUSTOM_TAG:-16}"

# Pick compose file — no merging, no rendered artifact.
if [ "$ENVIRONMENT" = "prod" ]; then
  COMPOSE_FILE=deploy/docker-compose.yaml
else
  COMPOSE_FILE=deploy/docker-compose.local.yaml
fi

# --- 1. Build the custom image (frappe + erpnext + crm + telephony + helpdesk) ---
# Skips the build if the image already exists locally (re-runs are fast).
# prod pins linux/amd64; dev builds for the host arch.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> Custom image $IMAGE already present, skipping build."
else
  echo "==> Building custom image $IMAGE (this can take a while)..."
  PLATFORM_ARGS=()
  if [ "$ENVIRONMENT" = "prod" ]; then
    PLATFORM_ARGS=(--platform linux/amd64)
  fi
  docker build \
    "${PLATFORM_ARGS[@]}" \
    --no-cache \
    --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
    --build-arg=FRAPPE_BRANCH=version-16 \
    --secret=id=apps_json,src=deploy/apps.json \
    --tag="$IMAGE" \
    --file=images/layered/Containerfile .
fi

# --- 2. Prepare bind-mount data dirs ---
DATA_DIR="$(cd "$(dirname "$0")" && pwd)/docker_data"
mkdir -p "$DATA_DIR/sites" "$DATA_DIR/redis-queue" "$DATA_DIR/db-backups"

# --- 3. Start the stack ---
# --pull=missing: use the locally built image; only pull if absent
# (Compose v5 ignores pull_policy).
echo "==> Starting containers (compose: $COMPOSE_FILE, env: $ENVIRONMENT)..."
FRAPPE_DATA_DIR="$DATA_DIR" docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --pull=missing

# --- 4. Wait for db + configurator ---
echo "==> Waiting for db to become healthy..."
for i in $(seq 1 60); do
  if FRAPPE_DATA_DIR="$DATA_DIR" docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" \
      exec -T db healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo "==> Waiting for configurator to finish..."
for i in $(seq 1 30); do
  state=$(docker inspect --format '{{.State.Status}}' "$PROJECT-configurator-1" 2>/dev/null || echo "missing")
  if [ "$state" = "exited" ]; then
    break
  fi
  sleep 5
done

# --- 5. Create the three sites ---
new_site() {
  local site="$1" app="$2"
  echo "==> Creating site $site (app: $app)..."
  FRAPPE_DATA_DIR="$DATA_DIR" docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T backend \
    bench new-site \
    --mariadb-user-host-login-scope=% \
    --db-root-password "$DB_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app "$app" \
    "$site"
}

if [ "$ENVIRONMENT" = "prod" ]; then
  new_site "erp.$DOMAIN"      erpnext
  new_site "crm.$DOMAIN"      crm
  new_site "helpdesk.$DOMAIN" helpdesk
  echo
  echo "==> Done. Point DNS at the server, install Caddy (deploy/Caddyfile), then open:"
  echo "  https://erp.$DOMAIN      (Administrator / $ADMIN_PASSWORD)"
  echo "  https://crm.$DOMAIN      (Administrator / $ADMIN_PASSWORD)"
  echo "  https://helpdesk.$DOMAIN (Administrator / $ADMIN_PASSWORD)"
else
  new_site erp.localhost      erpnext
  new_site crm.localhost      crm
  new_site helpdesk.localhost helpdesk
  echo
  PORT="${HTTP_PUBLISH_PORT:-8080}"
  echo "==> Done. Open in your browser:"
  echo "  http://erp.localhost:$PORT      (Administrator / $ADMIN_PASSWORD)"
  echo "  http://crm.localhost:$PORT      (Administrator / $ADMIN_PASSWORD)"
  echo "  http://helpdesk.localhost:$PORT (Administrator / $ADMIN_PASSWORD)"
fi
