# Xira (Custom OpenProject) — Server Deployment Guide

A complete, beginner-friendly walkthrough for deploying our custom OpenProject build (`xira`) onto the shared Linux server **without disturbing the existing production OpenProject** that already runs there.

This guide assumes you have **never** worked with Docker, CI/CD, GitHub Actions, Linux servers, or Ruby on Rails. Every command is spelled out. Run them in the order shown.

---

## 0. What we're building (high level)

```
   YOUR LAPTOP                 GITHUB                       LINUX SERVER (srv1307927)
   ───────────                 ──────                       ─────────────────────────
                                                            ┌────────────────────────┐
                                                            │  PROD OpenProject      │  ← UNTOUCHED
                                                            │  /opt/openproject      │     port 8081
                                                            │  containers:           │     image: openproject/openproject
                                                            │    openproject-web-1   │     network: openproject_default
                                                            │    openproject-cron-1  │
                                                            │    openproject-cache-1 │
                                                            │    ... etc             │
                                                            └────────────────────────┘
                                                            ┌────────────────────────┐
   git push to dev ─────▶  Workflow runs  ─── SSH ───▶      │  DEV OpenProject (NEW) │  ← THIS GUIDE
                            ├ build image on             ▶ │  /opt/openproject-dev  │     port 8082
                            │   ubuntu-latest               │  containers:           │     image: ghcr.io/excelerate-technologies/xira-custom
                            ├ push to GHCR                  │    op-dev-web          │     network: op-dev-net
                            └ ssh in & redeploy             │    op-dev-cron         │
                                                            │    op-dev-cache        │
                                                            │    ... etc             │
                                                            └────────────────────────┘
                                                                     │
                                                                     ▼
                                                            Azure Postgres
                                                            db: op_xira_dev (NEW, separate from prod's op_xira)
```

**The two stacks share NOTHING:**

| Resource | PROD (existing, do not touch) | DEV (we build this) |
|---|---|---|
| Server directory | `/opt/openproject` | `/opt/openproject-dev` |
| Compose project name | `openproject` | `openproject-dev` |
| Container names | `openproject-web-1`, `openproject-cron-1`, `openproject-cache-1`, `openproject-worker-1`, `openproject-hocuspocus-1`, `openproject-proxy-1` | `op-dev-web`, `op-dev-cron`, `op-dev-cache`, `op-dev-worker`, `op-dev-hocuspocus`, `op-dev-proxy` |
| Docker image | `openproject/openproject:17-slim` (pulled from Docker Hub) | `ghcr.io/excelerate-technologies/xira-custom:latest` (built by our CI from our own code) |
| Docker network | `openproject_default` (or whatever prod created) | `op-dev-net` |
| Host port | `8081` | `8082` |
| Bind mount root | `/opt/openproject/opdata` | `/opt/openproject-dev/opdata` |
| Postgres database | `op_xira` | `op_xira_dev` |
| `.env` file | `/opt/openproject/.env` | `/opt/openproject-dev/.env` |
| Caddy/proxy config | prod's existing | `/opt/openproject-dev/Caddyfile` (separate) |
| Public hostname | `xira.exceleratetechnologies.com` (prod) | `xira-dev.exceleratetechnologies.com` (dev) |

**No file is shared. No port collides. No container name collides. No network is shared. Prod stays alive throughout.**

---

## 1. Prerequisites checklist

Before you start, confirm you have:

- [ ] Admin access to the GitHub repo `Excelerate-Technologies/xira`
- [ ] SSH access to the server `srv1307927` (you can already log in once with `ssh root@srv1307927`)
- [ ] An Azure Postgres admin account that can create new databases (the same one prod uses is fine)
- [ ] Git Bash installed on your Windows laptop (you've already been using it)
- [ ] Docker Desktop installed on your laptop (you've already been using it)

If anything is missing, sort it before continuing.

---

## 2. Phase 1 — One-time GitHub setup

These steps configure GitHub so the automated deployment can work. You only do this once.

### 2.1 Generate the SSH key the GitHub Actions workflow will use

GitHub Actions needs a way to log into your server. We generate a dedicated key for that — never reuse your personal SSH key.

On your laptop, in Git Bash:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/xira_deploy_key -N "" -C "github-actions-xira-dev"
```

This creates two files:

- `~/.ssh/xira_deploy_key` — **PRIVATE key**. Treat like a password. Goes into GitHub.
- `~/.ssh/xira_deploy_key.pub` — **PUBLIC key**. Goes onto the server. Safe to share.

Show the **public** key (you'll paste this onto the server in step 2.4):

```bash
cat ~/.ssh/xira_deploy_key.pub
```

It looks like one long line starting with `ssh-ed25519`. Keep this Git Bash window open.

Show the **private** key (you'll paste this into GitHub in step 2.5):

```bash
cat ~/.ssh/xira_deploy_key
```

It's a multi-line block starting with `-----BEGIN OPENSSH PRIVATE KEY-----` and ending with `-----END OPENSSH PRIVATE KEY-----`. Copy the **entire block including the BEGIN and END lines.**

### 2.2 Generate a GHCR pull token

The server will pull our built Docker image from GHCR (GitHub Container Registry). Since the image is private, the server needs a token to authenticate.

1. Open https://github.com/settings/tokens
2. Click **Generate new token** → **Generate new token (classic)**
3. Note: `xira-server-pull`
4. Expiration: 1 year (set a calendar reminder to rotate)
5. Scopes: tick only **`read:packages`**
6. Click **Generate token**
7. Copy the token. It starts with `ghp_` and you'll only see it once.

Paste it into a temporary text file for now — you'll add it to GitHub secrets in step 2.5.

### 2.3 Add public key to the server

On your laptop:

```bash
ssh root@srv1307927
```

Now you're on the server. Make sure the `.ssh` directory exists with right permissions, then add the public key:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys
```

Nano opens. Move to the end of the file (Ctrl+End or scroll). Paste the entire public key line you copied in step 2.1 (`ssh-ed25519 AAAA...`). Save with `Ctrl+O` then `Enter`, exit with `Ctrl+X`.

Tighten permissions:

```bash
chmod 600 ~/.ssh/authorized_keys
```

Test the new key works (from a fresh laptop terminal, not on the server):

```bash
exit  # leave the server first
ssh -i ~/.ssh/xira_deploy_key root@srv1307927 "echo IT WORKS"
```

If it prints `IT WORKS`, you're set. If it asks for a password, the public key isn't installed correctly — repeat 2.3.

### 2.4 Configure GitHub repository secrets

Go to https://github.com/Excelerate-Technologies/xira/settings/secrets/actions

Click **New repository secret** for each of the five rows below:

| Secret name | What goes in the value field |
|---|---|
| `DEPLOY_HOST` | `srv1307927` (or the server's public IP) |
| `DEPLOY_USER` | `root` |
| `DEPLOY_PORT` | `22` (omit only if you've changed the SSH port) |
| `DEPLOY_SSH_KEY` | The full multi-line **private** key from step 2.1 (`-----BEGIN ... END-----`) |
| `GHCR_PULL_TOKEN` | The token starting with `ghp_` from step 2.2 |

After saving, you'll see all five names listed. The values become hidden — that's correct.

### 2.5 Allow workflows to push packages

By default GitHub Actions in an org has read-only access to packages. We need to grant write access at two levels.

**At the org level:**

1. Open https://github.com/organizations/Excelerate-Technologies/settings/actions
2. Scroll to **Workflow permissions**
3. Choose **Read and write permissions**
4. Click **Save**

**At the repo level:**

1. Open https://github.com/Excelerate-Technologies/xira/settings/actions
2. Scroll to **Workflow permissions**
3. Choose **Read and write permissions**
4. Click **Save**

If you skip these steps, the first deployment will fail at the `docker push` step with an HTTP 403.

---

## 3. Phase 2 — One-time server setup

These steps prepare a clean place on the server for the new dev stack. **Nothing here touches prod.**

### 3.1 Log into the server

```bash
ssh root@srv1307927
```

You should now see a prompt like `root@srv1307927:~#`. Every command in section 3 runs on the server.

### 3.2 Confirm prod is running and identify its containers (sanity check)

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
```

You should see your existing prod stack: containers named `openproject-web-1`, `openproject-cron-1`, etc., using image `openproject/openproject:17-slim`, with port `8081` published. **Do not touch any of these.**

### 3.3 Create the dev directory tree

```bash
mkdir -p /opt/openproject-dev/opdata
chown -R 1000:1000 /opt/openproject-dev/opdata
ls -la /opt/openproject-dev
```

You should see:

```
drwxr-xr-x  ... .
drwxr-xr-x  ... ..
drwxr-xr-x  ... opdata
```

The `1000:1000` ownership matches the `app` user inside the OpenProject container. If owners look different, the container won't be able to write attachments.

### 3.4 Verify Docker version

```bash
docker --version
docker compose version
```

You need Docker 20+ and Compose v2. If `docker compose version` errors out and only `docker-compose version` works, you have legacy Compose — replace `docker compose` with `docker-compose` everywhere in this guide.

---

## 4. Phase 3 — Create the dev database (one-time)

Even though prod uses Azure Postgres, the dev stack must use a **separate database** on the same server. This guarantees that wiping or experimenting on dev cannot corrupt prod data.

### 4.1 From your laptop (or the server, doesn't matter), create the empty database

```bash
psql "host=cex-db.postgres.database.azure.com port=5432 user=cx_pg_admin sslmode=require dbname=postgres" \
  -c "CREATE DATABASE op_xira_dev;"
```

Enter the password when prompted.

If you don't have `psql` installed locally, install it: https://www.postgresql.org/download/windows/. Or do it from the Azure Portal: **Postgres flexible server → Databases → Add → name = `op_xira_dev`**.

### 4.2 Verify the database is reachable

```bash
psql "host=cex-db.postgres.database.azure.com port=5432 user=cx_pg_admin sslmode=require dbname=op_xira_dev" -c "SELECT 1;"
```

Should print:

```
 ?column?
----------
        1
(1 row)
```

If you see `connection timed out` or `no pg_hba.conf entry`, your laptop's IP isn't allowlisted on Azure Postgres. The server's IP is already allowlisted (because prod uses it), so this only affects you running `psql` from the laptop.

### 4.3 Allowlist the server's IP if not already done

Already done if prod is connecting. If you ever change servers, go to Azure Portal → your Postgres flexible server → **Networking** → "Add current client IP address" or add the server's public IP manually.

---

## 5. Phase 4 — Copy config files to the server (one-time)

The repo's `deploy/` folder contains three template files we need on the server: `docker-compose.yml`, `Caddyfile`, and `.env.example`. We copy them up, then customize `.env` with real secrets (the example file goes in your `.gitignore`-clear position; the real `.env` never gets committed).

### 5.1 From your laptop, copy the files

In Git Bash on your laptop:

```bash
cd /c/Dheeraj/Projects/xira
scp -i ~/.ssh/xira_deploy_key \
    deploy/docker-compose.yml \
    deploy/Caddyfile \
    deploy/.env.example \
    root@srv1307927:/opt/openproject-dev/
```

Note: `scp` copies files over SSH. The `-i` flag tells it which key to use. The destination `/opt/openproject-dev/` already exists from step 3.3.

### 5.2 On the server, rename `.env.example` to `.env`

```bash
ssh root@srv1307927
cd /opt/openproject-dev
cp .env.example .env
ls -la
```

You should see all four files (`docker-compose.yml`, `Caddyfile`, `.env`, `.env.example`) and the `opdata` directory.

---

## 6. Phase 5 — Fill in the `.env` file (one-time)

The `.env` file holds every secret and every environment-specific setting. Open it on the server with nano:

```bash
nano /opt/openproject-dev/.env
```

You'll see entries already there from the example file. Change them to the values shown below. **Read each note carefully** — some require generating fresh values.

### 6.1 Image reference (don't change)

```env
OPENPROJECT_IMAGE=ghcr.io/excelerate-technologies/xira-custom
OPENPROJECT_TAG=latest
```

The GitHub Actions workflow overrides `OPENPROJECT_TAG` to the exact commit SHA on every deploy, so this default is only used when you manually run `docker compose up`.

### 6.2 Rails secret (generate a fresh value)

In a separate Git Bash window, run this and copy the output:

```bash
openssl rand -hex 32
```

Paste the result after `=`:

```env
SECRET_KEY_BASE=<paste here>
```

> Why this matters: Rails uses this secret to sign cookies. If it changes, all logged-in sessions get invalidated. Generate it once and don't change it after.

### 6.3 Hocuspocus secret (generate a fresh value, **different** from above)

Run again:

```bash
openssl rand -hex 32
```

Paste:

```env
COLLABORATIVE_SERVER_SECRET=<paste here>
```

### 6.4 Public URL settings

```env
OPENPROJECT_HOST__NAME=xira-dev.exceleratetechnologies.com
OPENPROJECT_HTTPS=true
OPENPROJECT_HSTS=true
PORT=8082
OPENPROJECT_RAILS__RELATIVE__URL__ROOT=
```

> Why `8082`: prod uses `8081`. Two stacks cannot share a host port. We pick the next free one.

### 6.5 Database (Azure)

```env
DB_POSTGRESDB_HOST=cex-db.postgres.database.azure.com
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=op_xira_dev
DB_POSTGRESDB_USER=cx_pg_admin
DB_POSTGRESDB_PASSWORD=SecurePasswordCEX%401
```

> URL-encoding: the password's literal value contains `@`. In a `postgres://` URL, `@` separates user from host. Write `%40` instead. Same logic for `:` (`%3A`), `/` (`%2F`), `#` (`%23`), `?` (`%3F`).

### 6.6 Bind mount

```env
OPDATA=/opt/openproject-dev/opdata
```

### 6.7 Hocuspocus URL

```env
COLLABORATIVE_SERVER_URL=wss://xira-dev.exceleratetechnologies.com/hocuspocus
```

> Note `wss://` (secure WebSocket), not `ws://`, because the public proxy will terminate TLS in front of dev.

### 6.8 SMTP (copy from prod's `.env`)

These are the same as prod since dev sends mail through the same Office 365 mailbox:

```env
IMAP_ENABLED=false
OPENPROJECT_SMTP__ADDRESS=smtp.office365.com
OPENPROJECT_SMTP__PORT=587
OPENPROJECT_SMTP__DOMAIN=exceleratetechnologies.com
OPENPROJECT_SMTP__AUTHENTICATION=login
OPENPROJECT_SMTP__USER__NAME=ticketsupport@exceleratetechnologies.com
OPENPROJECT_SMTP__PASSWORD=<copy from /opt/openproject/.env>
OPENPROJECT_SMTP__ENABLE__STARTTLS__AUTO=true
OPENPROJECT_MAIL__FROM=ticketsupport@exceleratetechnologies.com
```

To copy the SMTP password without exposing it on screen:

```bash
grep '^OPENPROJECT_SMTP__PASSWORD=' /opt/openproject/.env
```

(That reads from prod's `.env`. We're only **reading** prod's config here, never modifying it.)

### 6.9 Save and exit nano

`Ctrl+O` → `Enter` → `Ctrl+X`.

### 6.10 Lock down `.env` permissions

```bash
chmod 600 /opt/openproject-dev/.env
ls -la /opt/openproject-dev/.env
```

You should see `-rw-------`. This prevents other server users from reading the secrets.

---

## 7. Phase 6 — First deployment (one-time)

Now we trigger the first build and deployment.

### 7.1 Push the dev branch from your laptop

If you haven't already pushed `dev` to the new repo:

```bash
cd /c/Dheeraj/Projects/xira
git checkout dev   # or git checkout -b dev if it doesn't exist yet
git status
git push origin dev
```

If you've already pushed, fire a manual build instead:

1. Open https://github.com/Excelerate-Technologies/xira/actions
2. Click "Build and Deploy (dev)" in the left sidebar
3. Click the "Run workflow" dropdown on the right → "Run workflow" button

### 7.2 Watch the build

On https://github.com/Excelerate-Technologies/xira/actions:

- The job named **build-and-push** runs first. First time: 15–25 minutes.
- The job named **deploy** runs after, taking ~30 seconds.
- Each job has a green checkmark on success, red X on failure.

If `build-and-push` fails:
- Open the failed job, expand the failing step, read the error
- Most common cause: workflow permissions not set in 2.5 → fix and re-run

If `deploy` fails:
- Most common cause: SSH key wrong, server not reachable, or `GHCR_PULL_TOKEN` invalid
- Re-check secrets in 2.4

### 7.3 Run database migrations (once, after first successful build)

The `op_xira_dev` database is empty. OpenProject normally runs migrations automatically on container start, but for clarity we run them explicitly the first time:

```bash
ssh root@srv1307927
cd /opt/openproject-dev
docker compose -p openproject-dev run --rm web bundle exec rake db:migrate
docker compose -p openproject-dev run --rm web bundle exec rake db:seed
```

> What's happening: `bundle exec rake db:migrate` applies the OpenProject database schema (creates ~150 tables). `db:seed` populates the admin user and default data. Each takes 2–5 minutes.

### 7.4 Bring up the stack

```bash
docker compose -p openproject-dev up -d
docker compose -p openproject-dev ps
```

You should see 6 containers, all `Up`:

```
NAME                  IMAGE                                              STATUS
op-dev-cache          memcached                                          Up
op-dev-cron           ghcr.io/excelerate-technologies/xira-custom:...    Up
op-dev-hocuspocus     openproject/hocuspocus:17.3.1                      Up
op-dev-proxy          caddy:2-alpine                                     Up
op-dev-web            ghcr.io/excelerate-technologies/xira-custom:...    Up (healthy)
op-dev-worker         ghcr.io/excelerate-technologies/xira-custom:...    Up
```

`op-dev-web` may take 2–3 minutes to become `(healthy)`. Watch its logs:

```bash
docker logs -f op-dev-web
```

When you see `Listening on http://0.0.0.0:8080`, the app is ready. `Ctrl+C` to stop following.

### 7.5 First-time browser test (without DNS)

Test directly using the IP and port:

```
http://srv1307927:8082
```

Or from inside your office network if hostname resolves. Login: `admin` / `admin`. You'll be forced to change the password.

If that works, the stack is functional. The hostname/HTTPS layer comes next.

---

## 8. Phase 7 — Public hostname (DNS + reverse proxy in front)

The dev stack listens on port `8082` of the server. To make it reachable as `https://xira-dev.exceleratetechnologies.com`, we need DNS plus the existing public-facing reverse proxy on the server (whatever fronts prod) to also forward this hostname.

### 8.1 Add DNS record

Wherever your DNS is managed (Cloudflare, Azure DNS, etc.), add an A record:

```
Name:    xira-dev
Type:    A
Value:   <server public IP>
TTL:     300
```

Wait 1–10 minutes for propagation. Test:

```bash
nslookup xira-dev.exceleratetechnologies.com
```

Should return the server's IP.

### 8.2 Add a vhost to the public reverse proxy

Your server has *some* public-facing reverse proxy that handles TLS for `xira.exceleratetechnologies.com` and other hostnames. From your earlier `docker ps`, possible candidates:

- **Traefik** (`traefik:v3.6.2` was running) — most likely the public-facing TLS terminator
- **The prod openproject-proxy-1** (caddy) — only handles prod's hostname, won't help us
- A separate **nginx** if installed at the host level (not in a container)

The dev compose's caddy on `8082` is **internal** — it routes traffic between the dev caddy and dev web/hocuspocus. It does NOT do public TLS. The public proxy (traefik / nginx / whatever) needs to know about the new dev hostname.

The exact config depends on which public proxy you're using. **Skip this step for the first run** — use `http://srv1307927:8082` directly while testing. Once everything works internally, add the vhost. Common patterns:

**If traefik (Docker labels-based routing):** edit `/opt/openproject-dev/docker-compose.yml`, add labels to the `proxy:` service:

```yaml
  proxy:
    # ... existing config ...
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.xiradev.rule=Host(`xira-dev.exceleratetechnologies.com`)"
      - "traefik.http.routers.xiradev.entrypoints=websecure"
      - "traefik.http.routers.xiradev.tls.certresolver=letsencrypt"
      - "traefik.http.services.xiradev.loadbalancer.server.port=80"
    networks:
      - op-dev-net
      - traefik-public   # whatever network traefik is on
```

(You'd also need to confirm the traefik network name and add it under `networks:` at the bottom.)

**If host-level nginx:** create `/etc/nginx/sites-available/xira-dev`:

```nginx
server {
    listen 80;
    server_name xira-dev.exceleratetechnologies.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name xira-dev.exceleratetechnologies.com;

    ssl_certificate     /etc/letsencrypt/live/xira-dev.exceleratetechnologies.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/xira-dev.exceleratetechnologies.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8082;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

Then:

```bash
ln -s /etc/nginx/sites-available/xira-dev /etc/nginx/sites-enabled/xira-dev
nginx -t
systemctl reload nginx
certbot --nginx -d xira-dev.exceleratetechnologies.com
```

> Whatever you do here, **do not edit prod's vhost**. You're adding a new vhost file, not modifying an existing one.

Tell me which public proxy you're using and I'll give the exact config — for now, the IP-and-port test is enough.

---

## 9. Phase 8 — Verify isolation (one-time, after first successful deploy)

Run these commands on the server. They confirm prod and dev don't share anything.

### 9.1 Container names don't overlap

```bash
docker ps --format '{{.Names}}' | sort
```

You should see two non-overlapping groups:

```
op-dev-cache
op-dev-cron
op-dev-hocuspocus
op-dev-proxy
op-dev-web
op-dev-worker
openproject-cache-1
openproject-cron-1
openproject-hocuspocus-1
openproject-proxy-1
openproject-web-1
openproject-worker-1
```

### 9.2 Networks don't overlap

```bash
docker network ls
```

You'll see one network for prod (named after prod's compose project, often `openproject_default`) and `op-dev-net` for dev. They're independent.

### 9.3 Volumes don't overlap

```bash
docker volume ls | grep -E 'openproject|op-dev'
```

Prod volumes have prefix `openproject_`. Dev volumes have prefix `openproject-dev_` (caddy data/config) or are bind mounts (which don't show up in `volume ls`).

### 9.4 Bind mounts are different paths

```bash
ls -la /opt/openproject/.env       # prod's
ls -la /opt/openproject-dev/.env   # dev's
```

Different files, different content.

### 9.5 Port 8081 is prod, 8082 is dev

```bash
ss -tlnp | grep -E ':(8081|8082)'
```

Should show port 8081 owned by a different docker-proxy process than port 8082.

If all five checks pass, the stacks are fully isolated.

---

## 10. Phase 9 — Day-to-day workflow

Once everything is set up, your normal workflow is:

```bash
# On your laptop, in the repo
cd /c/Dheeraj/Projects/xira
git checkout dev

# ... edit code ...

git add <files you changed>
git commit -m "describe what you changed"
git push origin dev
```

That's it. The push triggers GitHub Actions, which builds and redeploys automatically. Open the Actions tab to watch progress (~3–8 minutes for non-first builds since layers are cached).

You **never** need to SSH into the server for routine deploys.

---

## 11. Common operations (run on the server in `/opt/openproject-dev`)

### Status and logs

```bash
# Show all dev containers
docker compose -p openproject-dev ps

# Tail web logs
docker compose -p openproject-dev logs -f web

# Tail worker logs (background jobs)
docker compose -p openproject-dev logs -f worker

# All services at once
docker compose -p openproject-dev logs -f
```

### Restart after `.env` change

```bash
cd /opt/openproject-dev
docker compose -p openproject-dev down
docker compose -p openproject-dev up -d
```

### Apply a single new service config (no full restart)

```bash
docker compose -p openproject-dev up -d --force-recreate web
```

### Run a Rails command inside the running container

```bash
docker compose -p openproject-dev exec web bundle exec rails runner "puts User.count"
```

### Open a Rails console (advanced)

```bash
docker compose -p openproject-dev exec web bundle exec rails console
```

Type `exit` to leave.

### Reset a forgotten admin password

```bash
docker compose -p openproject-dev exec web bundle exec rails runner "
u = User.find_by(login: 'admin')
u.password = 'NewPassword123!'
u.password_confirmation = 'NewPassword123!'
u.force_password_change = true
u.failed_login_count = 0
u.status = 1
u.save!(validate: false)
puts 'OK'"
```

### Manually pull a fresh image and restart

```bash
echo "<GHCR_PULL_TOKEN>" | docker login ghcr.io -u dheeraj-et --password-stdin
docker compose -p openproject-dev pull
docker compose -p openproject-dev up -d
docker logout ghcr.io
```

### Stop everything (keeps data, just shuts containers off)

```bash
docker compose -p openproject-dev down
```

### Stop and **wipe** caddy state (does NOT touch the database or `opdata`)

```bash
docker compose -p openproject-dev down -v
```

### Wipe the database (DANGER — only if rebuilding from scratch)

```bash
psql "host=cex-db.postgres.database.azure.com port=5432 user=cx_pg_admin sslmode=require dbname=postgres" \
  -c "DROP DATABASE op_xira_dev;"
psql "host=cex-db.postgres.database.azure.com port=5432 user=cx_pg_admin sslmode=require dbname=postgres" \
  -c "CREATE DATABASE op_xira_dev;"
```

Then re-run section 7.3 to migrate and seed.

---

## 12. Troubleshooting

### Symptom: `docker compose` says "no such file or directory"

You're not in the right directory. Run `cd /opt/openproject-dev` first.

### Symptom: Container immediately exits with `pull access denied`

The server can't pull from GHCR. Re-login:

```bash
echo "<GHCR_PULL_TOKEN>" | docker login ghcr.io -u dheeraj-et --password-stdin
docker compose -p openproject-dev pull
```

### Symptom: Web container restarts every minute

Check logs:

```bash
docker logs op-dev-web --tail 50
```

Common causes:
- **`Connection refused` to Postgres** → wrong `DB_POSTGRESDB_HOST` or Azure firewall blocking server IP
- **`SSL is required`** → you have `sslmode=disable` in the URL (compose hardcodes `sslmode=require` for the cloud)
- **`scheme postgres does not accept registry part`** → password contains `@` and isn't URL-encoded as `%40`
- **`Migrations are pending`** → run section 7.3

### Symptom: Browser shows "502 Bad Gateway"

`op-dev-web` isn't healthy yet. Wait 2–3 minutes. If it never becomes healthy, check `docker logs op-dev-web` for boot errors.

### Symptom: GitHub Actions deploy step fails with "permission denied (publickey)"

The SSH key isn't installed on the server, or `DEPLOY_SSH_KEY` is the wrong format. Re-do section 2.1–2.4. The private key in GitHub must include the `-----BEGIN ... END-----` lines.

### Symptom: GitHub Actions build step fails with HTTP 403 on docker push

Workflow permissions not set. Re-do section 2.5.

### Symptom: Healthcheck fails forever

Inside the web container, hit the health endpoint manually:

```bash
docker exec op-dev-web curl -v http://localhost:8080/health_checks/default
```

If it 500s, look at `docker logs op-dev-web` — likely a missing env var or DB connection issue.

### Symptom: Port 8082 already in use

Something else on the server is using that port. Find what:

```bash
ss -tlnp | grep :8082
```

Either stop the conflicting process or change `PORT=8083` in `/opt/openproject-dev/.env` and restart.

### Symptom: Prod stack shows up in dev's `docker compose ps` (or vice versa)

You forgot the `-p openproject-dev` flag. Always include it. Without `-p`, compose uses the directory name as the project name, which can confuse things if you ever cd into the wrong place.

---

## 13. Rollback to a previous deploy

Every successful deploy tags the image with both `:latest` and `:sha-<commit>`. To roll back to an earlier known-good build:

### 13.1 Find the SHA you want

On https://github.com/Excelerate-Technologies/xira/actions, find a green run from the date/commit you want to roll back to. The commit SHA is shown.

### 13.2 Apply it on the server

```bash
ssh root@srv1307927
cd /opt/openproject-dev
nano .env
```

Change:

```env
OPENPROJECT_TAG=sha-<full-commit-sha>
```

Save (`Ctrl+O`, `Enter`, `Ctrl+X`), then:

```bash
docker compose -p openproject-dev pull
docker compose -p openproject-dev up -d
```

The next normal `git push origin dev` will overwrite this back to whatever was just built. So a rollback is temporary unless you also `git revert` the bad commit.

---

## 14. Disaster recovery — if dev gets into an unrecoverable state

Because dev shares **nothing** with prod, you can completely nuke and rebuild dev without any prod risk. The five steps:

```bash
ssh root@srv1307927

# 1. Stop and remove dev containers + dev's caddy volumes
cd /opt/openproject-dev
docker compose -p openproject-dev down -v

# 2. Remove dev's bind-mount data (drops all uploads/attachments)
rm -rf /opt/openproject-dev/opdata
mkdir -p /opt/openproject-dev/opdata
chown -R 1000:1000 /opt/openproject-dev/opdata

# 3. Drop and recreate the dev database
psql "host=cex-db.postgres.database.azure.com port=5432 user=cx_pg_admin sslmode=require dbname=postgres" \
  -c "DROP DATABASE op_xira_dev;"
psql "host=cex-db.postgres.database.azure.com port=5432 user=cx_pg_admin sslmode=require dbname=postgres" \
  -c "CREATE DATABASE op_xira_dev;"

# 4. Bring back up + migrate + seed
cd /opt/openproject-dev
docker compose -p openproject-dev pull
docker compose -p openproject-dev run --rm web bundle exec rake db:migrate
docker compose -p openproject-dev run --rm web bundle exec rake db:seed
docker compose -p openproject-dev up -d

# 5. Verify prod is still untouched (sanity)
docker ps --filter 'name=openproject-' --format '{{.Names}}\t{{.Status}}'
```

After step 5 you should see all `openproject-*` containers still `Up` — prod was never affected.

---

## 15. Glossary (skim if anything sounds unfamiliar)

- **Container**: A running instance of a Docker image. Like a tiny isolated VM. Stops cleanly with `docker stop`.
- **Image**: A frozen snapshot of an application + its dependencies, built from a `Dockerfile`. Containers run from images.
- **Compose**: A tool to run multiple containers together as a single stack, defined in `docker-compose.yml`.
- **Compose project name** (`-p`): A namespace for a stack. Two stacks with different project names won't collide on networks, container names, or volumes.
- **GHCR**: GitHub Container Registry — where our built images are hosted.
- **Bind mount**: A directory on the host file system mounted into a container. Survives container restarts. Used here for `opdata`.
- **Volume** (named): Docker-managed storage that lives in `/var/lib/docker/volumes`. Used here for caddy state.
- **Healthcheck**: A periodic probe Docker uses to decide if a container is "healthy". Defined in `docker-compose.yml`.
- **Migration**: A Ruby on Rails database schema change script. `rake db:migrate` applies all pending ones.
- **Slim image target**: A Dockerfile stage that produces only the Rails app, no bundled Postgres. We use this so we can use external Azure Postgres.
- **Caddy / nginx / traefik**: Reverse proxies. They sit in front of the app and handle TLS, hostnames, routing.
- **GHCR pull token**: A GitHub access token with `read:packages` scope so the server can pull our private image.

---

## 16. Quick-reference cheatsheet

| What I want to do | Where to run | Command |
|---|---|---|
| Trigger a normal deploy | laptop | `git push origin dev` |
| Manually trigger a deploy | browser | https://github.com/Excelerate-Technologies/xira/actions → Run workflow |
| See running dev containers | server | `docker compose -p openproject-dev ps` |
| Tail dev web logs | server | `docker compose -p openproject-dev logs -f web` |
| Restart dev stack | server | `cd /opt/openproject-dev && docker compose -p openproject-dev down && docker compose -p openproject-dev up -d` |
| Run a Rails console | server | `docker compose -p openproject-dev exec web bundle exec rails console` |
| Stop dev (keep data) | server | `cd /opt/openproject-dev && docker compose -p openproject-dev down` |
| Roll back to specific build | server | edit `.env` → `OPENPROJECT_TAG=sha-...` → `docker compose -p openproject-dev pull && up -d` |
| Verify prod still alive | server | `docker ps --filter 'name=openproject-' --format '{{.Names}}\t{{.Status}}'` |
| Delete and rebuild dev | server | section 14 |

---

When something doesn't match what's described here, paste the exact command output and I'll diagnose. Don't edit prod paths or prod containers to "fix" dev — every command in this guide targets `openproject-dev` or `op-dev-*` only.
