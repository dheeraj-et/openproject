# Dev OpenProject deployment guide

Step-by-step playbook for deploying our custom-built OpenProject (`xira-custom`)
to the shared Linux server, fully isolated from the existing production stack.
We update this file as we hit issues — see the **Troubleshooting log** at the bottom.

---

## 1. How the pieces fit together

```
   Your laptop (Windows)            GitHub                Linux server
   ────────────────────             ──────                ────────────
   git push origin dev  ──▶  Actions runner        SSH      /opt/openproject       (PROD, untouched)
                              ├─ build slim image  ────▶    /opt/openproject-dev   (DEV) ★ ← us
                              └─ push to GHCR              docker compose pull
                                                            docker compose up -d
                                                                       │
                                                                       ▼
                                                           Azure Postgres (separate DB)
```

**Key facts**
- The Docker image (`xira-custom:latest`) is built on GitHub's runners, **not** on the server.
- The server only stores: `docker-compose.yml`, `.env`, `Caddyfile`, and an `opdata/` directory.
- Dev runs side-by-side with prod using *different*: host port (8082 vs 8081), container names (`op-dev-*`), bind-mount path, network name, compose project name (`openproject-dev`), and database (`op_xira_dev`).
- Local laptop testing uses `C:\Users\DP\openproject-dev\` with a `docker-compose.override.yml` that disables SSL — that override is **local-only** and must not be committed.

---

## 2. Prerequisites checklist

- [ ] Forked repo on GitHub
- [ ] SSH access to the server (deploy user + key)
- [ ] An SSH private key the GitHub Action can use to log in (we'll generate)
- [ ] DBA willing to create an empty Postgres database `op_xira_dev` (and a user with rights on it)
- [ ] DNS for `xira-dev.exceleratetechnologies.com` → server IP (optional for first test, you can use port 8082 directly)

---

## 3. Phase 0 — Push your code to GitHub

Files you've edited locally that need to go to GitHub:
- `.gitattributes`
- `.github/workflows/deploy.yml`
- `deploy/.env.example`
- `deploy/Caddyfile`
- `deploy/docker-compose.yml`

Files that **must NOT be pushed**:
- `C:\Users\DP\openproject-dev\docker-compose.override.yml` (laptop-only; lives outside the repo so this is automatic)
- Anything containing real secrets or DB passwords

### 3.1 Branch decision
Our workflow (`.github/workflows/deploy.yml`) is configured to trigger on pushes to the `dev` branch.
You are currently on `stable/17`. The cleanest setup is to **push your `stable/17` branch up as `dev`** on your fork.

### 3.2 Commit and push
```bash
cd /c/Dheeraj/Projects/openproject

# See what's changed
git status

# Stage exactly the files we want
git add .gitattributes .github/workflows/deploy.yml deploy/

# Eyeball the staged set
git status

# Commit
git commit -m "Add isolated dev deploy stack and workflow"

# Confirm you're pushing to YOUR fork, not opf/openproject
git remote -v

# Push current branch up as 'dev' on your fork
git push origin stable/17:dev
```

After this, browse to your fork on GitHub → **Actions** tab. The workflow will *try* to run, but it will **fail** until we add the secrets in Phase 1 — that's expected.

---

## 4. Phase 1 — Configure GitHub Actions secrets

In your fork on GitHub: **Settings → Secrets and variables → Actions → New repository secret**.

| Secret name        | What it is                                            |
|--------------------|-------------------------------------------------------|
| `DEPLOY_HOST`      | Server hostname or IP                                 |
| `DEPLOY_USER`      | SSH user on the server                                |
| `DEPLOY_SSH_KEY`   | **Private** SSH key the action uses to log in (full PEM contents) |
| `DEPLOY_PORT`      | Optional. SSH port. Skip if 22.                       |
| `GHCR_PULL_TOKEN`  | GitHub Personal Access Token with `read:packages` scope, used by the server to pull from GHCR |

### 4.1 Generate the deploy keypair (one-time, on your laptop)
```bash
ssh-keygen -t ed25519 -f ~/.ssh/op_dev_deploy -N "" -C "op-dev-deploy"
```
This creates two files:
- `~/.ssh/op_dev_deploy`     ← private key → goes into `DEPLOY_SSH_KEY`
- `~/.ssh/op_dev_deploy.pub` ← public key → install on the server

### 4.2 Install the public key on the server
SSH in once with whatever access you currently have, then:
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat >> ~/.ssh/authorized_keys <<'EOF'
<paste contents of op_dev_deploy.pub here>
EOF
chmod 600 ~/.ssh/authorized_keys
```

### 4.3 Generate the GHCR pull token
On GitHub: **Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token**.
- Scope: only `read:packages`
- Copy the token, paste it as `GHCR_PULL_TOKEN`.

---

## 5. Phase 2 — Prepare the server (one-time)

### 5.1 Create the dev directory
```bash
ssh <DEPLOY_USER>@<DEPLOY_HOST>

sudo mkdir -p /opt/openproject-dev/opdata
sudo chown -R $USER:$USER /opt/openproject-dev
```

### 5.2 Copy compose files from your laptop to the server
From a Git Bash window on your laptop:
```bash
cd /c/Dheeraj/Projects/openproject
scp deploy/docker-compose.yml deploy/Caddyfile deploy/.env.example \
    <DEPLOY_USER>@<DEPLOY_HOST>:/opt/openproject-dev/
```

### 5.3 Create `.env` on the server
Back on the server:
```bash
cd /opt/openproject-dev
cp .env.example .env
nano .env
```
Fill in:
- `SECRET_KEY_BASE=`         — generate with `openssl rand -hex 32`
- `COLLABORATIVE_SERVER_SECRET=` — same, a fresh value
- `DB_POSTGRESDB_HOST=cex-db.postgres.database.azure.com`
- `DB_POSTGRESDB_DATABASE=op_xira_dev`
- `DB_POSTGRESDB_USER=...` and `DB_POSTGRESDB_PASSWORD=...` (URL-encode special chars)
- `OPENPROJECT_HOST__NAME=xira-dev.exceleratetechnologies.com`
- `OPENPROJECT_IMAGE=ghcr.io/<your-github-username>/<your-repo-name>-custom`
- `OPENPROJECT_TAG=latest`
- `OPDATA=/opt/openproject-dev/opdata`

### 5.4 First-time GHCR login on the server
```bash
echo "<GHCR_PULL_TOKEN>" | docker login ghcr.io -u <your-github-username> --password-stdin
```

### 5.5 First-time DB setup
The Azure DB exists but is empty — apply schema and seed defaults once:
```bash
cd /opt/openproject-dev
docker compose -p openproject-dev pull
docker compose -p openproject-dev run --rm web bundle exec rake db:migrate
docker compose -p openproject-dev run --rm web bundle exec rake db:seed
```

### 5.6 Bring up the stack
```bash
docker compose -p openproject-dev up -d
docker compose -p openproject-dev ps
docker compose -p openproject-dev logs -f web
```
Wait for `Listening on http://0.0.0.0:8080`, then open:
- `http://<server-ip>:8082` (direct), or
- `https://xira-dev.exceleratetechnologies.com` (once DNS is set)

Default login: `admin` / `admin` — forced password change on first login.

---

## 6. Phase 3 — Routine deploys (after one-time setup)

Every push to `dev` automatically:
1. Builds the image on GitHub
2. Pushes it to GHCR with tags `latest` and `sha-<commit>`
3. SSHes to the server and runs `docker compose pull && up -d`

```bash
# typical day-to-day flow
git checkout stable/17
# ... edit code ...
git commit -am "your change"
git push origin stable/17:dev
# Watch GitHub → Actions tab
```

You **don't** need to log into the server for routine deploys.

---

## 7. Common operations (run on the server, in `/opt/openproject-dev`)

```bash
# stack status
docker compose -p openproject-dev ps

# tail logs
docker compose -p openproject-dev logs -f web
docker compose -p openproject-dev logs -f worker

# restart one service after .env change
docker compose -p openproject-dev up -d --force-recreate web

# stop the stack (keeps volumes)
docker compose -p openproject-dev down

# Rails console (advanced)
docker compose -p openproject-dev exec web bundle exec rails console
```

---

## 8. Troubleshooting log

Add entries as we hit problems. Each entry: **symptom → cause → fix**.

### 2026-04-30 · `server does not support SSL` on local laptop
- **Symptom:** `connection to server at "192.168.65.254", port 5432 failed: server does not support SSL`
- **Cause:** Compose hard-codes `sslmode=require` but local Windows-host Postgres doesn't speak SSL.
- **Fix:** Local-only `docker-compose.override.yml` at `C:\Users\DP\openproject-dev\` overrides the DB URL with `sslmode=disable`. Server deploys keep SSL on.

### 2026-04-30 · `ActiveRecord::PendingMigrationError`
- **Symptom:** "Migrations are pending. … 94 pending migrations".
- **Cause:** Fresh empty database, schema not yet applied.
- **Fix:** `docker compose -p openproject-dev run --rm web bundle exec rake db:migrate` (and `rake db:seed` if also empty of data).

### 2026-04-30 · Browser refused on `http://localhost:8080`
- **Symptom:** "site refused to connect".
- **Cause:** 8080 is the *internal* container port. Only the Caddy proxy is published, on port 8082.
- **Fix:** Use `http://localhost:8082`.

### 2026-04-30 · Login rejected: "Invalid user or password or the account is blocked"
- **Symptom:** `admin/admin` rejected after a few attempts.
- **Cause:** Account auto-locked from failed attempts, or seed never created the admin.
- **Fix:** Reset via `rails runner` — sets new password and zeroes `failed_login_count`:
  ```bash
  docker compose -p openproject-dev exec web bundle exec rails runner "
  u = User.find_by(login: 'admin')
  u.password = 'AdminAdmin1!'; u.password_confirmation = 'AdminAdmin1!'
  u.force_password_change = true; u.failed_login_count = 0; u.status = 1
  u.save!(validate: false); puts 'OK'"
  ```
