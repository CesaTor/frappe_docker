# Adding a new Helpdesk project (site)

Use this when you need a **new, isolated Helpdesk** for a project
(e.g. `school`, `office`, `hive`).

## Concept

In Frappe, a **site** is a fully isolated unit — its own database, data, users,
and settings. A "project" is therefore **its own Helpdesk site**, not a section
inside an existing one. All sites live on the **same bench** (same containers +
same MariaDB); adding a project just adds a new site (a new database).

Because Frappe is **host-based**, each site needs its **own hostname**, and the
**site name must equal the hostname**.

## Naming convention

```
<project>.helpdesk.requrv.io
```

| Project | URL                                 | Site name (must match)      |
| ------- | ----------------------------------- | --------------------------- |
| school  | `https://school.helpdesk.requrv.io` | `school.helpdesk.requrv.io` |
| office  | `https://office.helpdesk.requrv.io` | `office.helpdesk.requrv.io` |
| hive    | `https://hive.helpdesk.requrv.io`   | `hive.helpdesk.requrv.io`   |

Pick `<project>` = the project slug. The only hard rule: **site name = hostname**.

---

## Runbook (per new project)

Set `PROJECT` to the slug (e.g. `school`) and `SITE` to the full hostname.

```sh
PROJECT=school
SITE=school.helpdesk.requrv.io
```

### 1. DNS

Point an A/AAAA record for `$SITE` at the server's IP. Wait for it to propagate
(`dig +short $SITE`).

### 2. Caddy

Add a block to `/etc/caddy/Caddyfile` (and to `deploy/Caddyfile` for the record):

```caddy
school.helpdesk.requrv.io {
	reverse_proxy localhost:8080
}
```

Then reload:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy issues/renews the Let's Encrypt cert automatically once DNS resolves.

### 3. Create the site

```sh
cd /path/to/frappe_docker
set -a && source deploy/.env && set +a

docker compose --project-name frappe -f deploy/docker-compose.yaml exec -T backend \
  bench new-site \
  --mariadb-user-host-login-scope=% \
  --db-root-password "$DB_PASSWORD" \
  --admin-password "$ADMIN_PASSWORD" \
  --install-app helpdesk \
  "$SITE"
```

> `--install-app helpdesk` also pulls in `telephony` automatically (it's a
> required app of Helpdesk and is already in the image).

### 4. Verify

```sh
# Site exists
docker compose --project-name frappe -f deploy/docker-compose.yaml \
  exec -T backend ls sites/ | grep "$SITE"

# HTTP 200 through Caddy
curl -s -o /dev/null -w "%{http_code}\n" "https://$SITE/"
```

Log in at `https://$SITE/` with `Administrator` / `$ADMIN_PASSWORD`, then set up
the project's agents, customers, and settings.

---

## Day-2 operations for a project site

```sh
# Migrate after an app upgrade
docker compose --project-name frappe -f deploy/docker-compose.yaml \
  exec -T backend bench --site "$SITE" migrate

# Back up
docker compose --project-name frappe -f deploy/docker-compose.yaml \
  exec -T backend bench --site "$SITE" backup

# Drop (destructive — archives the site + drops its database)
docker compose --project-name frappe -f deploy/docker-compose.yaml \
  exec -T backend bench drop-site "$SITE" --force --no-backup --db-root-password "$DB_PASSWORD"
```

---

## Notes & trade-offs

- **Isolation:** separate sites = separate databases = hard data isolation.
  Use this when projects must not see each other's data (different customers/teams).
- **Cost:** cheap — shares the existing workers/scheduler/containers; the only
  additions are a new database in MariaDB and a bit of memory.
- **Scaling:** if a single bench ever becomes a bottleneck, you can move a
  project to its **own bench** (separate containers + DB) — see
  `docs/02-setup/07-single-server-example.md`. Not needed for a handful of sites.
- **Alternative (weaker isolation):** one Helpdesk site with a custom "Project"
  field to logically separate data. Only use this if projects must **share**
  agents/config. For distinct projects, separate sites is the right model.
