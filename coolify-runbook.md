# Classroom Deployment Platform — Coolify Runbook

> **⚠️ Status:** Two big pivots happened in August 2026. Reflected inline where relevant, but calling them out here:
>
> 1. **Public entry point changed** from Cloudflare Tunnel + Let's Encrypt DNS-01 to **CS IT's HAProxy** (SNI passthrough on `haproxy1.cs.byu.edu`) + a CS-provided `*.cs.byu.edu` wildcard cert. Sections §7 (Cloudflare Tunnel) and §8 (DNS-01 TLS) are **historical**.
> 2. **Student access model changed** from "students don't have Coolify accounts, admin creates Applications" to **self-serve teams via GitHub OAuth**. Instructor runs [`scripts/provision-teams.sh`](scripts/provision-teams.sh) from a roster CSV to create teams + user rows + server rows in one shot. Students sign in via GitHub OAuth (invite-gated) and create their own Projects → Environments → Applications per [`student-guide.md`](student-guide.md) → Part B → Setup. Section §11 below reflects this.

This is the **server-side** setup guide for `rigel.cs.byu.edu`, the GPU-equipped front-end machine that hosts:

- **LiteLLM** — the single proxy fronting the two GPU inference boxes (`castor`, `pollux`), exposed to students as `ml-capstone.cs.byu.edu:4000`
- **Coolify** — a self-hosted, GitHub-webhook-driven "push to deploy" platform students use for their class projects; admin UI at `ml-capstone-admin.cs.byu.edu` (live, VPN-only, GitHub OAuth login)
- **TLJH (The Littlest JupyterHub)** — JupyterHub for classes that need notebooks; runs behind Coolify's Traefik, uses qsynology-served LDAP homes (same auth as `castor` and `pollux`). **Currently deferred** — port 8080 conflicts with Coolify's own proxy; needs re-planning.
- **4× NVIDIA A6000 GPUs** — available to student Docker containers via Coolify for GPU-accelerated deploys

Students learn the industry-standard flow: push to a GitHub repo → tests run in Actions → deploy webhook fires → Coolify pulls, builds, deploys, routes traffic.

Only one path on `rigel` is reachable from the public internet: the GitHub webhook endpoint (`ml-capstone.cs.byu.edu/webhooks/*`) and the Coolify deploy API (`/api/v1/deploy`), both via CS IT's HAProxy doing SNI passthrough. Everything else — LLM endpoint, deployed apps, admin UI — requires the BYU CS VPN.

---

## 1. Architecture

```
+-------------------------------------------------------------------------------+
|                          STUDENT WORKSTATION                                  |
|                                                                               |
|  [ VS Code / browser / git ]                                                  |
|         |                                                                     |
|         | BYU VPN                                                             |
|         v                                                                     |
+---------+---------------------------------------------------------------------+
          |
          | (all internal traffic)
          v
+---------+---------------------------------------------------------------------+
|                       RIGEL.CS.BYU.EDU                                        |
|                                                                               |
|  Traefik (bundled with Coolify)  :80 / :443                                   |
|      routes internal wildcard *.ml-capstone.cs.byu.edu -> student containers      |
|      also routes ml-capstone-admin.cs.byu.edu -> coolify:8080 (admin UI)      |
|      TLS termination via CS-provided *.cs.byu.edu DigiCert wildcard           |
|                                                                               |
|  LiteLLM              :4000        chat + FIM pools -> castor, pollux         |
|  Coolify UI           :8000                                                   |
|  Coolify realtime     :6001                                                   |
|  Coolify terminal     :6002                                                   |
|  TLJH (JupyterHub)    :8080        SSSD/LDAP auth, qsynology-mounted /home    |
|                                                                               |
|  Docker + NVIDIA Container Toolkit                                            |
|   +------------------------------------------+                                |
|   | student containers (Coolify-managed):    |                                |
|   |   alice-web        CPU-only              |                                |
|   |   bob-inference    GPU 0 reserved        |                                |
|   |   carol-training   GPU 1 reserved        |                                |
|   |   (GPU 2 + GPU 3 free)                   |                                |
|   +------------------------------------------+                                |
|                                                                               |
+---------+---------------------------------------------------------------------+
          |                                                    ^
          | (outbound: git clone, model pulls, npm, etc.)      | GitHub webhook + Actions
          v                                                    |
     Public internet                              +------------+-------------+
          |                                       | CS IT HAProxy            |
          v                                       | (haproxy1.cs.byu.edu)    |
     GitHub -------- webhook (push) ------------->+ SNI passthrough :443     |
                                                  | -> rigel :443 (Traefik)  |
                                                  +--------------------------+

                Castor.cs.byu.edu                     Pollux.cs.byu.edu
                (vLLM chat :8000)                     (vLLM chat :8000)
                (vLLM FIM  :8010)                     (vLLM FIM  :8010)
                     ^                                      ^
                     |                                      |
                     +--- LiteLLM pool fan-out --------------+
```

Key points:

- **VPN is the primary access control.** Everything on `rigel` binds to interfaces reachable via the campus network. VPN users see the machine directly.
- **Only the webhook URL is public**, via Cloudflare Tunnel. No inbound ports opened on `rigel` for the internet at large.
- **TLS uses DNS-01 challenge** (not HTTP-01), because port 80 is not public. Certs are still real Let's Encrypt certs, browsers trust them.
- **GPUs are per-container.** Coolify apps opt in to GPUs via Docker Compose. A6000 has no MIG, so it's one container per GPU at a time.
- **TLJH coexists on the same host.** JupyterHub runs on `:8080` (HTTP only, localhost) and is reverse-proxied by Coolify's Traefik. Home directories are NFS-mounted from `qsynology` (matching `castor`/`pollux`), so users have the same files no matter which host they log into. TLJH-created spawner users (`jupyter-<name>`) are local, but per `dirs.home: /home/{username}`, notebooks open in the LDAP user's home, not in `/home/jupyter-<name>`.

---

## 2. Prerequisites

**Machine.** `rigel.cs.byu.edu`. Recommended baseline:

- 32+ CPU cores, 64 GB RAM, 1 TB NVMe SSD (Coolify build cache grows fast, and Docker images for ML workloads are large)
- 4× NVIDIA A6000 GPUs, drivers installed, `nvidia-smi` works
- Ubuntu 22.04 LTS or 24.04 LTS
- Static IP, campus DNS entry `rigel.cs.byu.edu`
- SSSD-joined to the classroom LDAP directory, with `/home` NFS-mounted from `qsynology` (10.55.0.30:/volume1/nethome). See `castor`'s `/etc/sssd/sssd.conf` for the reference config.
- Root or passwordless-sudo SSH access

**DNS.** Two record sets are needed:

- **Internal wildcard for student apps.** `*.ml-capstone.cs.byu.edu` and `ml-capstone.cs.byu.edu` → `rigel.cs.byu.edu` (or its IP). Only needs to resolve *inside* the campus network / VPN — coordinate with CS IT.
- **Public webhook subdomain.** `ml-capstone.cs.byu.edu` → the Cloudflare-managed CNAME the tunnel creates. This one is public because GitHub has to reach it. It only routes to the webhook path on Coolify, nothing else.

**DNS-01 API credentials.** To auto-issue TLS certs without exposing port 80 publicly, Traefik needs API access to the DNS zone that hosts `*.ml-capstone.cs.byu.edu`. Get an API token from CS IT or whichever provider manages the zone. If DNS-01 is not achievable, plain HTTP over VPN is a defensible fallback for a class — see §8.

**Cloudflare account.** Free tier is fine. You'll need a domain on Cloudflare's nameservers (or a subdomain delegated to Cloudflare) — this is what backs `ml-capstone.cs.byu.edu`.

**GitHub.** A class GitHub org students will be invited to. You'll create one GitHub App scoped to that org.

**Ports on `rigel`** (nothing here is exposed to the public internet — VPN clients hit them directly):

| Port | Service | Notes |
|------|---------|-------|
| 22   | SSH     | Admin only |
| 80   | Traefik | Internal — VPN clients hitting HTTP student apps + TLJH via reverse proxy (redirects to 443) |
| 443  | Traefik | Internal — VPN clients hitting HTTPS student apps + TLJH via reverse proxy |
| 4000 | LiteLLM | Internal — students' editors |
| 8000 | Coolify UI | Internal — VPN clients only |
| 6001 | Coolify realtime | Internal |
| 6002 | Coolify terminal | Internal |
| 8080 | TLJH    | Localhost only — Coolify's Traefik reverse-proxies HTTPS to it |
| 2049 | NFS     | Outbound only, to qsynology (10.55.0.30) for `/home` |

---

## 3. Base Host Preparation

```bash
# On rigel as root or with sudo:
apt-get update && apt-get upgrade -y
apt-get install -y curl ca-certificates ufw fail2ban

# Firewall — nothing exposed to the public internet.
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp                                         # SSH (bastion / campus)
ufw allow from <CAMPUS_CIDR> to any port 80              # HTTP student apps
ufw allow from <CAMPUS_CIDR> to any port 443             # HTTPS student apps
ufw allow from <CAMPUS_CIDR> to any port 4000            # LiteLLM
ufw allow from <CAMPUS_CIDR> to any port 8000            # Coolify UI
ufw allow from <CAMPUS_CIDR> to any port 6001            # Coolify realtime
ufw allow from <CAMPUS_CIDR> to any port 6002            # Coolify terminal
ufw enable
```

Replace `<CAMPUS_CIDR>` with the actual BYU campus / VPN subnet (ask CS IT). The `cloudflared` daemon does not require any inbound rules — it makes outbound connections only.

---

## 4. Install NVIDIA Container Toolkit

Docker needs to hand GPUs to containers. Install the NVIDIA Container Toolkit before Coolify so the runtime is available when Coolify's Docker engine starts.

```bash
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# Verify:
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

That last command should list all four A6000s. If it fails, Coolify's GPU flags won't work — fix it before continuing.

---

## 5. Install Coolify

Coolify ships a one-line installer.

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```

First-boot flow (open `http://rigel.cs.byu.edu:8000` from the VPN):

1. Create the admin (root) account.
2. Skip the "connect a server" step — Coolify defaults to `localhost`, which is what we want.
3. In **Settings → Instance**, set the "Instance Domain" to `ml-capstone.cs.byu.edu`. Coolify uses this when generating per-app subdomains.
4. Enable "Force HTTPS."

---

## 6. Install LiteLLM Alongside

LiteLLM does not conflict with Coolify — different port, different Docker network. Run it as an independent Docker container so it survives Coolify upgrades.

Create `/etc/litellm/config.yaml` with both GPU hosts in each pool:

```yaml
model_list:
  - model_name: classroom-chat
    litellm_params:
      model: openai/Qwen/Qwen3-Coder-Next-FP8
      api_base: http://castor.cs.byu.edu:8000/v1
      api_key: sk-noauth
  - model_name: classroom-chat
    litellm_params:
      model: openai/Qwen/Qwen3-Coder-Next-FP8
      api_base: http://pollux.cs.byu.edu:8000/v1
      api_key: sk-noauth
  - model_name: classroom-autocomplete
    litellm_params:
      model: openai/Qwen/Qwen2.5-Coder-7B
      api_base: http://castor.cs.byu.edu:8010/v1
      api_key: sk-noauth
  - model_name: classroom-autocomplete
    litellm_params:
      model: openai/Qwen/Qwen2.5-Coder-7B
      api_base: http://pollux.cs.byu.edu:8010/v1
      api_key: sk-noauth

litellm_settings:
  turn_off_message_logging: true   # keep student prompts out of logs
```

Then:

```bash
docker run -d --name litellm \
  --restart=always \
  -p 4000:4000 \
  -v /etc/litellm/config.yaml:/app/config.yaml \
  ghcr.io/berriai/litellm:main-stable \
  --config /app/config.yaml
```

Verify from a workstation on VPN: `curl http://ml-capstone.cs.byu.edu:4000/v1/models` should list `classroom-chat` and `classroom-autocomplete`.

---

## 7. Cloudflare Tunnel — **OBSOLETE (historical)**

> **⚠️ Not used in the current architecture.** Replaced 2026-08-07 by CS IT's HAProxy doing SNI passthrough on `haproxy1.cs.byu.edu → rigel:443`. Kept below for context on the original design decision. If you're setting up the class today, skip to §11 and see [`admin-guide.md`](admin-guide.md) for the current public entry point.

The tunnel exposes exactly one URL — the GitHub webhook path — with no inbound ports opened on `rigel`.

```bash
# Install cloudflared (one-time):
curl -fsSL https://pkg.cloudflare.com/install.sh | bash
apt-get install -y cloudflared

# Log in — opens a browser to auth with your Cloudflare account:
cloudflared tunnel login

# Create the tunnel:
cloudflared tunnel create class-coolify-webhook
# Note the tunnel ID it prints.

# Create /etc/cloudflared/config.yml:
cat > /etc/cloudflared/config.yml <<'EOF'
tunnel: <TUNNEL_ID>
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: ml-capstone.cs.byu.edu
    path: /webhooks/.*
    service: http://localhost:8000
  - service: http_status:404      # everything else -> 404
EOF

# Route the DNS name through the tunnel (creates a CNAME in Cloudflare DNS):
cloudflared tunnel route dns class-coolify-webhook ml-capstone.cs.byu.edu

# Install as a systemd service:
cloudflared service install
systemctl enable --now cloudflared
```

The `path: /webhooks/.*` restriction means Cloudflare will only proxy the webhook path — attempts to reach `ml-capstone.cs.byu.edu/anything-else` get a 404 at the edge without touching `rigel`.

Verify: `curl -I https://ml-capstone.cs.byu.edu/webhooks/source/github/events` from anywhere on the public internet. Should return a Coolify response (probably 405 Method Not Allowed on GET, which is fine — GitHub uses POST).

---

## 8. TLS for Student Apps via DNS-01 — **OBSOLETE (historical)**

> **⚠️ Not used in the current architecture.** Replaced 2026-08-07 by a CS IT-provided `*.cs.byu.edu` DigiCert wildcard cert (valid 2026-07-09 → 2027-01-23; set a January renewal reminder). Certs live at `/data/coolify/proxy/certs/star_cs_byu_edu.{fullchain.pem,key}` and Traefik terminates TLS directly from those files. No Let's Encrypt, no DNS-01, no API tokens. See §11b in the older history if you need the Traefik dynamic config that wires the cert in.

Traefik (inside Coolify) needs to prove control over `*.ml-capstone.cs.byu.edu` to Let's Encrypt, but we can't use HTTP-01 because port 80 is not public. DNS-01 works instead: Traefik drops a TXT record via the DNS provider's API.

In Coolify's UI: **Settings → Advanced → Custom Traefik Configuration** (path varies slightly by version). Add the DNS challenge provider config for whatever manages the DNS zone. Example for Cloudflare-hosted DNS:

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: <admin@cs.byu.edu>
      storage: /data/coolify/proxy/acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - 1.1.1.1:53
          - 8.8.8.8:53
```

And export the API token before restarting the proxy:

```bash
# In the Coolify env for the proxy container:
CF_DNS_API_TOKEN=<scoped-token-with-DNS-Edit-on-the-zone>
```

Restart Coolify's proxy from the UI. First cert issuance takes a couple minutes (Let's Encrypt polls the TXT record). After that, Traefik renews automatically.

**If DNS-01 is not achievable** (e.g. CS IT won't give you an API token): fall back to plain HTTP on the internal wildcard. Students see "Not Secure" in browser but VPN provides transport encryption. Set `Force HTTPS = false` in Coolify.

---

## 9. Create the GitHub App

1. In your class GitHub org, go to **Settings → Developer settings → GitHub Apps → New GitHub App**.
2. **Name:** `class-coolify-deploy`
3. **Homepage URL:** `https://ml-capstone.cs.byu.edu`
4. **Webhook URL:** `https://ml-capstone.cs.byu.edu/webhooks/source/github/events` (the exact path is in Coolify's UI when you create a GitHub source in §10)
5. **Webhook secret:** generate a random string; save it.
6. **Permissions** (Repository):
   - Contents: Read-only
   - Metadata: Read-only
   - Pull requests: Read-only
   - Webhooks: Read & write
   - Deployments: Read & write (optional)
7. **Subscribe to events:** Push, Pull request.
8. **Where can this app be installed?** **Any account.** Critical: if this is set to "Only on this account" (the default), students will not be able to install the App on their own personal GitHub accounts and the whole self-serve deploy flow breaks. If you already created the App with the default and need to change it later: https://github.com/settings/apps/ml-capstone-coolify (as the App owner) → scroll to this setting → change → Save.
9. Create the app → generate a **private key** (download the `.pem`).
10. Note the **App ID** and **Client ID**.
11. **Install App** → install it on the class org, "All repositories."

---

## 10. Wire the GitHub App into Coolify

Coolify UI: **Sources → New → GitHub App**. Fill in App ID, Client ID, Client Secret, Webhook Secret, and paste the `.pem` contents. Coolify validates against the GitHub API. Green check = ready.

---

## 11. Team & User Model — self-serve teams via GitHub OAuth

**Pivoted 2026-08-10.** The original plan was "students don't have Coolify accounts, admin creates all Applications." That's been superseded — students sign in via GitHub OAuth, land in a pre-provisioned team, and create their own Projects, Environments, and Applications through the UI.

Why the pivot: GitHub OAuth eliminates the password-management friction of individual accounts. Students click "Sign in with GitHub" once, no new password. That flips the trade-off — self-serve is now roughly as easy to set up as admin-provisioning, but has much better long-term properties (nearly zero ongoing professor workload, higher educational value, matches industry pattern).

### Admin accounts

- **1 root/admin account** for the instructor (created during first-boot with email + password). This account survives OAuth linking — instructor's GitHub email matches the admin row → OAuth just becomes an alternate credential.
- **TA accounts** created the same way as students below (a row in the roster CSV), or manually via Coolify UI → **Team → Members** if you want them in the root team specifically.
- **Registration Allowed = OFF** (Coolify UI → Settings → Advanced). This is what makes OAuth invite-only: only email addresses already in the `users` table can complete sign-in. An unknown GitHub account gets "Registration is disabled" at the OAuth handoff.

### Provisioning student teams (bulk)

Use [`scripts/provision-teams.sh`](scripts/provision-teams.sh). One invocation reads a roster CSV and writes to Coolify's Postgres directly (Coolify's REST API doesn't cover team or user creation as of v4.2):

```bash
# On rigel, in the docker group (or with sudo):
./scripts/provision-teams.sh                                         # dry-run against newest roster-*.csv
./scripts/provision-teams.sh --check-schema                          # inspect DB layout first
./scripts/provision-teams.sh --roster roster-2026-fall.csv --apply   # execute
```

Per row, the script (idempotently) creates:

1. **`users`** row (email lowercased — Coolify issue #6291 duplicates on case mismatch)
2. **`teams`** row with `personal_team=false`
3. **`team_user`** pivot with `role='admin'` (v4.2 broke the `member` role)
4. **`servers`** row named `ml-capstone` pointing at `host.docker.internal` (Coolify talks to Docker via the socket, not SSH)
5. **`server_settings`** row with `is_reachable=true`, `is_usable=true`, `is_sentinel_enabled=false` — without this the dashboard 500s

CSV shape (headers required): `team_name,email,name,github_username`. Multiple rows per email = user in multiple teams (this is how the "individual sandbox in Phase 1 → group team in Phase 2" arc works — Phase-2 rows get appended, Phase-1 rows stay).

Naming convention:
- Phase 1 (individual sandboxes): `<student-first-name> Sandbox` — e.g., `Alice Sandbox`
- Phase 2 (groups): `Group N` — e.g., `Group 1`

### What students do (in the UI)

See [`student-guide.md`](student-guide.md) → Part B → **Setup: Sign in and create your Coolify Applications** for the 11-step lab. Summary:

1. Sign in via GitHub OAuth at `https://ml-capstone-admin.cs.byu.edu`
2. Switch to their team via the team switcher
3. Install the `ml-capstone-coolify` GitHub App on their class repo
4. Create Project → prod + staging Environments → one Application per Environment (both point at the same repo, different branches: `main` for prod, `staging` for staging)
5. Assign domain per team's convention (`<team-slug>.ml-capstone.cs.byu.edu` and `<team-slug>-staging.ml-capstone.cs.byu.edu`)
6. Turn off Coolify's auto-deploy on both Applications (GitHub Actions drives the deploys instead)
7. Copy Deploy Webhook URLs + create an API token → paste as GitHub Actions secrets

### Cleanup / reset (for term-end or mid-term)

Not scripted yet — Phase 21 pending. For now: `docker exec coolify-db psql` and delete the team rows, or use the Coolify UI's Team → Danger Zone → Delete Team button.

---

## 12. Per-Resource Limits — Set These Before Any Deploys

Without limits, one runaway container OOMs the box and everyone loses LiteLLM + Coolify.

**Global Docker defaults** — `/etc/docker/daemon.json`:

```json
{
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 4096, "Soft": 4096 }
  },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

Then `systemctl restart docker`.

**Per-application resource limits in Coolify** — set on each student's Application resource under **Configuration → Resource Limits**:

- Memory: 4 GB (adjust to `total_ram / expected_concurrent_apps`)
- CPU: 2 cores
- Disk: 20 GB (persistent volumes count against this)

Under the self-serve model (§11), each team is its own quota domain. Set the same defaults on every team's Application resources. Coolify doesn't currently offer team-level quotas that flow down to Applications automatically — students set them per-Application during the onboarding lab, or you extend `provision-teams.sh` to seed shared env vars that Applications inherit.

**Disk pressure** — weekly prune:

```bash
0 3 * * 0  docker system prune -af --filter "until=168h" --volumes
```

---

## 13. GPU Allocation Policy

`rigel` has 4× A6000. A6000 doesn't support MIG, so it's one container per GPU at a time. Decide the policy up front:

**Recommended default: one GPU per team, first-come-first-served, "please stop when done."** Coolify won't schedule this — it just fails the container start if all GPUs are claimed. Communicate the etiquette in the student guide. If TLJH classes on this box also need GPU sessions, subtract those reservations from the pool (e.g. 1 GPU pinned to TLJH → 3 GPUs available to Coolify).

For a student to opt into GPU access, they add this to their app's Docker Compose:

```yaml
services:
  app:
    image: ...
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1              # or `device_ids: ["0"]` to pin
              capabilities: [gpu]
```

Coolify will pass `--gpus 1` to Docker on deploy. If all GPUs are taken, the container fails to start — check with `nvidia-smi` to see who's using what.

**Optional hardening if the free-for-all gets messy:**

- Track claims manually in a shared doc (student, GPU index, deadline).
- Limit GPU deploys to specific teams (mark some student teams as "GPU-eligible" in your onboarding notes).
- For long-running training jobs, require a scheduled window and enforce with a stop-and-remove cron.

---

## 14. Student-Facing Flow

Students never touch Coolify. What they see and do:

1. Instructor sends them (a) their assigned GitHub repo in the class org, and (b) their assigned app URL, e.g. `alice.ml-capstone.cs.byu.edu` (VPN only).
2. Clone the repo, write code, commit, `git push origin main`.
3. Within ~1 minute the webhook fires → Coolify pulls, builds, redeploys → their app is live at the assigned URL.
4. If they need env vars (secrets, API keys), they ask an admin to add them via Coolify UI — env vars intentionally aren't in the repo.
5. Need a GPU? Include the Docker Compose GPU block in their repo (§13). If a GPU can't be reserved, the container fails to start and the admin surfaces the error.

For students, "deploying" is `git push`. Nothing else. Give them the URL and the repo — they don't need to know Coolify exists.

**What students see when a deploy fails:** the auto-deploy either succeeds or leaves the previous version running. There's no UI feedback for students unless the admin surfaces build logs. Practical mitigations:

- Encourage a GitHub Actions workflow that runs `docker build .` on every push so students see build failures in GitHub's UI before Coolify tries.
- Give students an admin's contact for "my push didn't seem to update the site" issues — usually a build error the admin can paste from Coolify.

---

## 15. Backups

Nightly Coolify state dump:

```bash
# /etc/cron.daily/coolify-backup
docker exec coolify-db pg_dump -U coolify coolify | \
  gzip > /var/backups/coolify/coolify-$(date +\%F).sql.gz
find /var/backups/coolify -mtime +14 -delete
```

Student app *data* is a per-app problem — students configure backups for their own Postgres / volumes through Coolify's UI.

---

## 16. Upgrade & Teardown

**Upgrade Coolify:** UI → **Settings → Update**, or re-run the installer (idempotent).

**End of semester:**

1. Export team + resource list.
2. Revoke the GitHub App's org installation.
3. `systemctl stop cloudflared` (kills the public webhook path).
4. `docker compose -f /data/coolify/source/docker-compose.yml down`.
5. Snapshot `/data/coolify` if you want to preserve state.
6. LiteLLM container is independent — leave it or `docker rm -f litellm`.

---

## 17. Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Student push doesn't trigger deploy | `cloudflared` crashed, or GitHub webhook can't reach edge | `systemctl status cloudflared`; check GitHub App → Advanced → Recent Deliveries; retry from there |
| Build fails with "no space left" | Docker build cache full | Run the prune cron manually |
| All apps 502 | Traefik crashed or Coolify updated mid-request | `docker restart coolify-proxy` |
| TLS cert renewal fails | DNS-01 API token expired or revoked | Rotate CF token; restart proxy |
| LiteLLM unreachable | Container died, or firewall reload dropped rules | `docker ps`; re-apply `ufw allow` lines |
| GPU app fails: "could not select device driver" | NVIDIA Container Toolkit not installed / Docker not restarted | Re-run §4; `systemctl restart docker` |
| GPU app fails: "no such device" or "all GPUs in use" | Another container has claimed all 4 (or TLJH is holding some) | `nvidia-smi` to identify; ask the holder to stop |
| TLJH login fails, "user not found" | SSSD not running or LDAP unreachable | `systemctl status sssd`; `getent passwd <user>`; check qsynology reachability |
| TLJH notebook opens in `/home/jupyter-<user>` not `/home/<user>` | `dirs.home` config lost | `sudo tljh-config set dirs.home /home/{username} && sudo tljh-config reload` |
| `rigel` fully offline | Hardware / network / OS | Coolify + LiteLLM + apps all down until recovery. LLM users can fall back to direct-to-vLLM on castor/pollux — see the admin guide's emergency section |

---

## 18. Why This Design

- **Coolify over Dokku:** students learn the GitHub-webhook workflow that mirrors industry CI/CD.
- **GitHub App over OAuth:** one credential to manage, org-scoped, one-click revoke at term end.
- **Coexists with LiteLLM on `rigel`:** LiteLLM is CPU-cheap and needs no GPU. Coolify + LiteLLM + LLM proxy on one box is easier to reason about than two.
- **VPN + Cloudflare Tunnel (one narrow route) instead of public exposure:** the box has zero inbound ports open to the internet. GitHub webhooks reach Coolify via the tunnel, everything else lives on the campus network.
- **DNS-01 instead of HTTP-01:** real Let's Encrypt certs without exposing port 80 publicly. Works because `*.ml-capstone.cs.byu.edu` only needs to resolve on VPN, not to Let's Encrypt.
- **GPUs on `rigel` for student containers:** students can deploy GPU-accelerated apps (inference, small training, media). A6000-per-container is a hard cap — plan a policy before demand outstrips supply.
- **TLJH on the same box:** consolidates the JupyterHub deployment for GPU-heavy classes. Home directories on qsynology mean users see the same files whether they log into `castor`, `pollux`, or `rigel`. Coolify's Traefik terminates TLS for both student apps and TLJH — one cert lifecycle.
