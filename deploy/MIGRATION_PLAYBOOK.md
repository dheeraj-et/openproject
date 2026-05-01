# OpenProject (XIRA) — Custom Schema Migration Playbook

Reference for running migrations against a non-`public` Postgres schema (e.g. `xira_dev`)
that lives in the same database as production. Every step assumes you are in
`~/openproject-dev/` on the host with Docker Desktop running.

---

## 0. One-time setup (already done)

### 0a. Compose files inject `search_path` into the DB URL

`deploy/docker-compose.yml` (the repo file) — both `OPENPROJECT_DB_URL` and `DATABASE_URL`
include `&options=-c%20search_path%3D${DB_POSTGRESDB_SCHEMA:-public}`.

`docker-compose.override.yml` (local-only, `sslmode=disable`) — same `options=` suffix
on all 6 URL lines (`web`, `worker`, `cron`).

URL encoding inside `options=`:
- `%20` = space
- `%3D` = `=`
- `%2C` = `,`

If you ever need `public` as a fallback for extensions (it is NOT needed here because
`btree_gist`, `pg_trgm`, `unaccent`, `plpgsql` all live in `pg_catalog`), append
`%2Cpublic` after the schema name.

### 0b. `.env` sets the schema name

```
DB_POSTGRESDB_SCHEMA=xira_dev
```

---

## 1. Pre-flight: prove the connection is on the right schema

```bash
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "SHOW search_path;" -c "SELECT current_schema();" -c "SELECT current_database();"'
```

Required output:
- `search_path` = `xira_dev`
- `current_schema` = `xira_dev`
- `current_database` = `op_xira`

If `current_schema` says `public`, STOP. The compose URL is not being applied. Likely
causes: `docker-compose.override.yml` overrode the URL without the `options=` suffix,
or the container is using a stale image. Fix before going any further.

---

## 2. Backup the target schema

From inside the container (writes to the OPDATA bind mount):
```bash
docker compose run --rm web bash -lc 'pg_dump "$DATABASE_URL" --schema=xira_dev --no-owner --no-acl -f /var/openproject/assets/xira_dev_backup_$(date +%Y%m%d_%H%M%S).sql'
```

Or from the host (requires `pg_dump` installed locally):
```bash
pg_dump "postgres://cx_pg_admin:SecurePasswordCEX%401@cex-db.postgres.database.azure.com:5432/op_xira?sslmode=require" \
  --schema=xira_dev --no-owner --no-acl \
  -f ~/xira_dev_backup_$(date +%Y%m%d_%H%M%S).sql
```

Verify file size:
```bash
ls -lh ~/openproject-dev/opdata/xira_dev_backup_*.sql
```

---

## 3. Inspect current migration state

Count migrations in target schema:
```bash
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "SELECT count(*) FROM schema_migrations;"'
```

Count in production schema (sanity reference — must NOT change after migration):
```bash
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "SELECT count(*) FROM public.schema_migrations;"'
```

Full per-migration status:
```bash
docker compose run --rm web bin/rails db:migrate:status RAILS_ENV=production | tail -30
```

---

## 4. Run the migration

Always use `run --rm`, never `exec`. The web container restart-loops on
`PendingMigrationError`, which kills any `exec`-ed command with SIGKILL (exit 137).

```bash
docker compose stop web worker cron
docker compose run --rm web bin/rails db:migrate RAILS_ENV=production
```

If output is silent or hangs, retry with trace:
```bash
docker compose run --rm web bin/rails db:migrate RAILS_ENV=production --trace
```

---

## 5. Post-migration verification

```bash
# Status should show all migrations as `up`
docker compose run --rm web bin/rails db:migrate:status RAILS_ENV=production | tail -30

# Count should equal pre-migration count + number of new migrations
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "SELECT count(*) FROM schema_migrations;"'

# Production count should be UNCHANGED
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "SELECT count(*) FROM public.schema_migrations;"'
```

---

## 6. Bring up the full stack

```bash
docker compose up -d
docker compose logs web --tail=80 -f
```

Expected boot lines:
```
=> Booting Puma
=> Rails 8.1.3 application starting in production
[1] Puma starting in cluster mode...
[1] * Listening on http://0.0.0.0:8080
[1] - Worker 0 (PID: ...) booted
[1] - Worker 1 (PID: ...) booted
```

App is reachable at `http://localhost:8082` (port from `.env`).

---

## 7. Rollback / restore (if migration fails)

```bash
# Drop and recreate the schema
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "DROP SCHEMA xira_dev CASCADE; CREATE SCHEMA xira_dev;"'

# Restore from backup
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -f /var/openproject/assets/xira_dev_backup_<TIMESTAMP>.sql'
```

---

## Common pitfalls / gotchas

| Symptom | Cause | Fix |
| --- | --- | --- |
| `current_schema = public` | `options=` missing from DATABASE_URL | Re-check both compose file and override |
| `db:migrate` exits with code 137, no output | Web container in restart loop, SIGKILL on exec | Use `docker compose run --rm`, not `exec` |
| `function unaccent does not exist` | Extension not on search_path | Add `,public` to search_path (`%2Cpublic`) |
| `PendingMigrationError` on boot after migrating | Schema mismatch between Rails connection and where migrations ran | Re-verify `current_schema()` matches expected |
| Override URL silently wins over repo URL | docker compose merges service env, override takes priority | Keep both files in sync OR delete override |

---

## Quick reference — single-command flow

When everything is set up correctly, the full migrate-and-boot sequence is:

```bash
# Verify schema
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "SELECT current_schema();"'

# Backup
docker compose run --rm web bash -lc 'pg_dump "$DATABASE_URL" --schema=xira_dev --no-owner --no-acl -f /var/openproject/assets/xira_dev_backup_$(date +%Y%m%d_%H%M%S).sql'

# Migrate
docker compose stop web worker cron
docker compose run --rm web bin/rails db:migrate RAILS_ENV=production

# Verify
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "SELECT count(*) FROM schema_migrations;"'

# Boot
docker compose up -d
docker compose logs web --tail=50 -f
```

---

## Useful one-off commands

Open a Rails console against the live schema:
```bash
docker compose exec web bin/rails console -e production
```

Open a `psql` shell:
```bash
docker compose exec web bash -lc 'psql "$DATABASE_URL"'
```

Check what env the container actually sees:
```bash
docker compose exec web printenv DATABASE_URL OPENPROJECT_DB_URL DB_POSTGRESDB_SCHEMA
```

Check which schemas exist in the database:
```bash
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "\dn"'
```

List extensions and which schema they live in:
```bash
docker compose run --rm web bash -lc 'psql "$DATABASE_URL" -c "SELECT extname, n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY extname;"'
```

Check container memory / CPU (host shell):
```bash
docker stats --no-stream
docker inspect op-dev-web --format '{{.State.OOMKilled}} {{.HostConfig.Memory}}'
```

Stop everything cleanly:
```bash
docker compose down
```

Stop and also wipe local volumes (caddy data only — does NOT touch the database):
```bash
docker compose down -v
```
