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

## Dev vs Production

- **Dev:** `deploy/docker-compose.local.yaml` — runs natively on host arch (arm64 on Apple Silicon), `*.localhost` sites, no proxy.
- **Production:** `deploy/docker-compose.yaml` — same stack, real subdomain sites (`<app>.<DOMAIN>`) behind Caddy (`deploy/Caddyfile`).
- No `platform` pin — image builds for host arch. Add `platform: linux/amd64` per-service if you need hard lock.

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

### To move to production

`setup.sh` reads `ENVIRONMENT` and `DOMAIN` from `deploy/.env`:

1. **Configure** the env for prod:
   ```sh
   cp deploy/.env.example deploy/.env
   # set DB_PASSWORD, ADMIN_PASSWORD, ENVIRONMENT=prod, DOMAIN=requrv.io
   ```
2. **Run** the same script — it picks `deploy/docker-compose.yaml` and creates the `erp/crm/helpdesk.<DOMAIN>` sites:
   ```sh
   bash deploy/setup.sh
   ```
3. **Point DNS** A/AAAA records for `erp.requrv.io`, `crm.requrv.io`,
   `helpdesk.requrv.io` at the server, and install **Caddy** with
   `deploy/Caddyfile` (Let's Encrypt is automatic).

---

## Files

| File                      | Purpose                                                                                                          |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `apps.json`               | Apps baked into the custom image: `erpnext`, `crm`, `telephony`, `helpdesk`.                                     |
| `.env.example`            | Template for `.env` — copy it, then set passwords, `ENVIRONMENT`, `DOMAIN`.                                      |
| `.env`                    | Secrets & tuning: `DB_PASSWORD`, `ADMIN_PASSWORD`, `ENVIRONMENT`, `DOMAIN`, image.                               |
| `setup.sh`                | Env-aware: builds image (if missing), starts stack, creates 3 sites. `dev` → `docker-compose.local.yaml`; `prod` → `docker-compose.yaml`. |
| `docker-compose.local.yaml` | **Dev** compose file (local).                                                                                    |
| `docker-compose.yaml`     | **Prod** compose file (single file, includes db/redis/bind-mounts/db-backup).                                    |
| `Caddyfile`               | **Prod-only** reference: Caddy reverse proxy + Let's Encrypt for the 3 domains.                                  |
| `ADD-HELPDESK-PROJECT.md` | Runbook: add a new isolated Helpdesk site for a project (school/office/hive/...).                                |
| `build.log` / `setup.log` | Captured output from the last build / setup run.                                                                 |

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

## Data & backups (what lives where)

Persistent data is bind-mounted into **`deploy/docker_data/`** so it survives
container removal and is visible on the host:

| Host folder                        | Container path                 | What's in it                          |
| ---------------------------------- | ------------------------------ | ------------------------------------- |
| `docker_data/sites/`               | `/home/frappe/frappe-bench/sites` | Site configs, private files, assets  |
| `docker_data/redis-queue/`         | `/data`                        | Redis queue persistence (AOF/RDB)     |
| `docker_data/db-backups/db-*.sql.gz` | — (written by `db-backup`)   | Daily full MariaDB dumps, last 7 kept |

**The MariaDB data dir is deliberately NOT bind-mounted.** On macOS the host
folders are APFS (case-insensitive); MariaDB then force-sets
`lower_case_table_names=2`, an unsupported combo with InnoDB, and
`bench new-site` dies with `ERROR 1033 "Incorrect information in file ... .frm"`.
The db therefore keeps its **named volume** (case-sensitive, inside Docker's
Linux VM), and the `db-backup` service writes a full `mariadb-dump` to
`docker_data/db-backups/` every 24h (first dump right after startup).

- **Backup:** copy `deploy/docker_data/` (sites + redis + db dumps).
- **Restore DB:** start the stack with a fresh `db` volume, then
  `gunzip -c docker_data/db-backups/db-<ts>.sql.gz | docker compose --project-name frappe -f deploy/docker-compose.yaml exec -T db mariadb` (or `docker-compose.local.yaml` for dev).
- `docker compose down -v` removes the db volume — the dumps in
  `docker_data/db-backups/` are your safety net.

---

## Gotchas (learned the hard way)

- **`pull_policy` is ignored by Compose v5.** The base `compose.yaml` sets
  `pull_policy: missing`, but Compose v5 still pulls by default. `setup.sh`
  passes `--pull=missing` explicitly to use the locally built image.
- **No platform pin.** Both compose files omit `platform` — they run natively on host arch (arm64 on Apple Silicon, amd64 on servers).
- **Quote passwords in `.env`.** `ADMIN_PASSWORD`/`DB_PASSWORD` may contain
  special characters (`&`, `!`, `$`). They are quoted so the file is safe for
  both Docker Compose and `source` in bash. An unquoted `&` makes bash treat the
  rest of the line as a background command.
- **Helpdesk needs `telephony`** in the image (see above).
- **Never bind-mount the MariaDB data dir on macOS.** Case-insensitive APFS
  forces `lower_case_table_names=2` → InnoDB `.frm` corruption (error 1033)
  mid `new-site`. Keep the db on its named volume; rely on the daily dumps in
  `docker_data/db-backups/`. (On a case-sensitive Linux fs a bind mount would
  work, but the dump-based backup is used everywhere for consistency.)

---

## Operations

```sh
# Stop the stack
docker compose --project-name frappe -f deploy/docker-compose.local.yaml down  # dev
# or deploy/docker-compose.yaml for prod

# Start it again
docker compose --project-name frappe -f deploy/docker-compose.local.yaml up -d --pull=missing  # dev

# Migrate a site after an app update
docker compose --project-name frappe -f deploy/docker-compose.local.yaml \
  exec backend bench --site erp.localhost migrate
```

See `docs/04-operations/01-site-operations.md` for the full command reference.
