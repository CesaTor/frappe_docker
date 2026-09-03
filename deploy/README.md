# Deploy — ERPNext + CRM + Helpdesk

A single Frappe **bench** hosting three sites, built for **local development** on
Apple Silicon (macOS, arm64) with **no reverse proxy** (direct `:8080` access).

| Site                 | App      | URL (dev)                      |
| -------------------- | -------- | ------------------------------ |
| `erp.localhost`      | ERPNext  | http://erp.localhost:8080      |
| `crm.localhost`      | CRM      | http://crm.localhost:8080      |
| `helpdesk.localhost` | Helpdesk | http://helpdesk.localhost:8080 |

`*.localhost` resolves to `127.0.0.1` on macOS automatically — no `/etc/hosts` edits.

## Login

| Field                 | Value                                      |
| --------------------- | ------------------------------------------ |
| **Email** (the field) | `Administrator`                            |
| **Password**          | your `ADMIN_PASSWORD` (from `deploy/.env`) |

> **Use `Administrator`, not the email.** The login field is labeled "Email",
> but Frappe matches the user by the user's **name** — and the admin user's name
> is `Administrator` (its email `admin@example.com` is _not_ used for the lookup).
> Entering `admin@example.com` returns "Invalid credentials". This applies to all
> three sites. On first login, ERPNext opens the setup wizard (language, company,
> currency, fiscal year).

---

## ⚠️ Dev (arm64) vs Production (amd64)

**This is the main thing to remember when going to production.**

- **Dev (this setup):** runs on an **Apple Silicon Mac (arm64)**. The image is built
  for `linux/arm64` and `deploy/compose.arm64.yaml` forces every service to
  `platform: linux/arm64`.
- **Production:** your server is **x86_64 (amd64)**. The base `compose.yaml`
  already hardcodes `platform: linux/amd64` on every service, so you must **NOT**
  include the arm64 override, and you must **rebuild the image for amd64**.

If you deploy the arm64 image / arm64 override to an amd64 server, Compose will
try to pull an amd64 image that doesn't exist and fail with
`pull access denied ... repository does not exist`.

### Production URLs (one subdomain per app)

Frappe resolves the site by the **`Host` header** and bakes the site name into
static-asset paths, so each app needs its **own hostname**. Sub-path routing
(e.g. `tools.requrv.ai/crm`) is **not supported** — Frappe always emits
root-absolute URLs (`/assets/...`, `/api/...`), which would hit the wrong site.

| URL                          | App      | Site name (must match) |
| ---------------------------- | -------- | ---------------------- |
| `https://erp.requrv.io`      | ERPNext  | `erp.requrv.io`        |
| `https://crm.requrv.io`      | CRM      | `crm.requrv.io`        |
| `https://helpdesk.requrv.io` | Helpdesk | `helpdesk.requrv.io`   |

> Need a **separate Helpdesk per project** (school / office / hive / ...)?
> Each project is its own site at `<project>.helpdesk.requrv.io`.
> See [`ADD-HELPDESK-PROJECT.md`](ADD-HELPDESK-PROJECT.md).

### To move to production (amd64)

`setup.sh` is environment-aware — it reads `ENVIRONMENT` and `DOMAIN` from
`deploy/.env`. On the amd64 server:

1. **Configure** the env for prod:
   ```sh
   cp deploy/.env.example deploy/.env
   # set DB_PASSWORD, ADMIN_PASSWORD, ENVIRONMENT=prod, DOMAIN=requrv.io
   ```
2. **Run** the same script — it builds for `linux/amd64`, omits the arm64
   override, and creates the `erp/crm/helpdesk.<DOMAIN>` sites:
   ```sh
   bash deploy/setup.sh
   ```
3. **Point DNS** A/AAAA records for `erp.requrv.io`, `crm.requrv.io`,
   `helpdesk.requrv.io` at the server, and install **Caddy** with
   `deploy/Caddyfile` (Let's Encrypt is automatic).

> The arm64 override is only applied when `ENVIRONMENT=dev`. On any amd64 host
> with `ENVIRONMENT=prod`, services keep the default `linux/amd64` platform.

---

## Files

| File                      | Purpose                                                                                                                                                           |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps.json`               | Apps baked into the custom image: `erpnext`, `crm`, `telephony`, `helpdesk`.                                                                                      |
| `.env.example`            | Template for `.env` — copy it, then set passwords, `ENVIRONMENT`, `DOMAIN`.                                                                                       |
| `.env`                    | Secrets & tuning: `DB_PASSWORD`, `ADMIN_PASSWORD`, `ENVIRONMENT`, `DOMAIN`, image.                                                                                |
| `setup.sh`                | Env-aware: builds the image (if missing), renders compose, starts the stack, creates the 3 sites. `ENVIRONMENT=dev` → arm64/localhost; `prod` → amd64/subdomains. |
| `compose.arm64.yaml`      | **Dev-only** override: forces all services to `linux/arm64`. Omit on amd64.                                                                                       |
| `Caddyfile`               | **Prod-only** reference: Caddy reverse proxy + Let's Encrypt for the 3 domains.                                                                                   |
| `ADD-HELPDESK-PROJECT.md` | Runbook: add a new isolated Helpdesk site for a project (school/office/hive/...).                                                                                 |
| `compose.rendered.yaml`   | Generated by `setup.sh` (the actual compose file used).                                                                                                           |
| `build.log` / `setup.log` | Captured output from the last build / setup run.                                                                                                                  |

### Why `telephony` is in `apps.json`

Helpdesk's `hooks.py` declares `required_apps = ["telephony"]`. Without it,
`bench new-site --install-app helpdesk` fails with
`ModuleNotFoundError: No module named 'telephony'`. It's a small Frappe app
(`frappe/telephony`, branch `develop`) and must be present in the image.

---

## Quick start (dev)

```sh
# 1. Set real passwords in deploy/.env (DB_PASSWORD, ADMIN_PASSWORD)
# 2. Run the setup
bash deploy/setup.sh
```

`setup.sh` is idempotent-ish: it skips the image build if `frappe-requrv:16`
already exists, and re-running it re-attempts site creation.

---

## Gotchas (learned the hard way)

- **`pull_policy` is ignored by Compose v5.** The base `compose.yaml` sets
  `pull_policy: missing`, but Compose v5 still pulls by default. `setup.sh`
  passes `--pull=missing` explicitly to use the locally built image.
- **Platform mismatch on Apple Silicon.** `compose.yaml` hardcodes
  `linux/amd64`; on an arm64 Mac you must add `compose.arm64.yaml` (see above).
- **Quote passwords in `.env`.** `ADMIN_PASSWORD`/`DB_PASSWORD` may contain
  special characters (`&`, `!`, `$`). They are quoted so the file is safe for
  both Docker Compose and `source` in bash. An unquoted `&` makes bash treat the
  rest of the line as a background command.
- **Helpdesk needs `telephony`** in the image (see above).

---

## Operations

```sh
# Stop the stack
docker compose --project-name frappe -f deploy/compose.rendered.yaml down

# Start it again
docker compose --project-name frappe -f deploy/compose.rendered.yaml up -d --pull=missing

# Migrate a site after an app update
docker compose --project-name frappe -f deploy/compose.rendered.yaml \
  exec backend bench --site erp.localhost migrate
```

See `docs/04-operations/01-site-operations.md` for the full command reference.
