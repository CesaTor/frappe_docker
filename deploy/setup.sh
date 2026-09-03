#!/usr/bin/env bash
#
# Deploys a single Frappe bench hosting three sites: ERPNext, CRM, Helpdesk.
#
# Two targets, selected by ENVIRONMENT in deploy/.env:
#   dev  (default) -> host arch, arm64 override on Apple Silicon, *.localhost sites, no proxy.
#   prod          -> linux/amd64, no arm64 override, real subdomain sites (<app>.<DOMAIN>).
#
# Usage:
#   1. cp deploy/.env.example deploy/.env   (then set DB_PASSWORD, ADMIN_PASSWORD,
#      ENVIRONMENT, DOMAIN)
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

# --- 1. Build the custom image (frappe + erpnext + crm + telephony + helpdesk) ---
# Skips the build if the image already exists locally (re-runs are fast).
# prod builds explicitly for linux/amd64; dev builds for the host arch.
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

# --- 2. Render the compose file ---
# The arm64 override is only for Apple Silicon dev. prod keeps the default amd64.
ARM64_OVERRIDE=()
if [ "$ENVIRONMENT" = "dev" ]; then
  ARM64_OVERRIDE=(-f deploy/compose.arm64.yaml)
fi
echo "==> Rendering compose file (environment: $ENVIRONMENT)..."
docker compose --env-file "$ENV_FILE" \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.noproxy.yaml \
  "${ARM64_OVERRIDE[@]}" \
  config > deploy/compose.rendered.yaml

# --- 3. Start the stack ---
# --pull=missing: use the locally built image; only pull if it's absent
# (Compose v5 ignores the pull_policy field and pulls by default).
echo "==> Starting containers..."
docker compose --project-name "$PROJECT" -f deploy/compose.rendered.yaml up -d --pull=missing

# --- 4. Wait for db + configurator ---
echo "==> Waiting for db to become healthy..."
for i in $(seq 1 60); do
  if docker compose --project-name "$PROJECT" -f deploy/compose.rendered.yaml \
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
  docker compose --project-name "$PROJECT" -f deploy/compose.rendered.yaml exec -T backend \
    bench new-site \
    --mariadb-user-host-login-scope=% \
    --db-root-password "$DB_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app "$app" \
    "$site"
}

if [ "$ENVIRONMENT" = "prod" ]; then
  # Site names must match the hostnames exactly (Frappe is host-based).
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
  echo "==> Done. Open in your browser:"
  echo "  http://erp.localhost:8080      (Administrator / $ADMIN_PASSWORD)"
  echo "  http://crm.localhost:8080      (Administrator / $ADMIN_PASSWORD)"
  echo "  http://helpdesk.localhost:8080 (Administrator / $ADMIN_PASSWORD)"
fi
