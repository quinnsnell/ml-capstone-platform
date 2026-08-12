# Classroom Deployment Platform — Coolify Runbook

This is the **server-side** setup guide for `rigel.cs.byu.edu`, the GPU-equipped front-end machine that hosts:

- **LiteLLM** — the single proxy fronting the two GPU inference boxes (`castor`, `pollux`), exposed to students as `ml-capstone.cs.byu.edu:4000`
- **Coolify** — a self-hosted, GitHub-webhook-driven "push to deploy" platform students use for their class projects; admin UI at `ml-capstone-admin.cs.byu.edu` (live, publicly reachable via CS IT HAProxy, gated by GitHub OAuth invite-only signin)
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
- **Public entry point is CS IT's HAProxy**, doing SNI passthrough from `haproxy1.cs.byu.edu:443` → `rigel:443` (Traefik). Only the GitHub webhook path and the Coolify deploy API are reachable that way — everything else on `rigel` requires VPN.
- **TLS is a CS-provided `*.cs.byu.edu` DigiCert wildcard** cert, terminated by Traefik directly from files on disk. No Let's Encrypt, no DNS-01, no API tokens. Valid 2026-07-09 → 2027-01-23; set a January renewal reminder.
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

**DNS** (coordinate all of these with CS IT — see [`tickets/README.md`](tickets/README.md) for the ticket templates that got them):

- **Wildcard for student apps.** `*.ml-capstone.cs.byu.edu` → `rigel.cs.byu.edu`. Resolves both on VPN (for students hitting their apps) and publicly (so GitHub webhooks land at HAProxy, which forwards to rigel).
- **Coolify admin alias.** `ml-capstone-admin.cs.byu.edu` → `rigel.cs.byu.edu`. Public; HAProxy passes SNI through to Traefik → Coolify UI.

**TLS.** CS IT provisions a `*.cs.byu.edu` DigiCert wildcard cert. Files live on rigel at `/data/coolify/proxy/certs/star_cs_byu_edu.{fullchain.pem,key}`, and Traefik terminates TLS from those files. No Let's Encrypt or DNS-01 setup needed. The `*.cs.byu.edu` wildcard covers one level only, so `ml-capstone-admin.cs.byu.edu` gets HTTPS but two-level names like `<team>.ml-capstone.cs.byu.edu` do not — student apps serve HTTP over VPN. See §8 for the Traefik dynamic-config that wires the cert in.

**Public entry point.** CS IT's HAProxy (`haproxy1.cs.byu.edu`) does SNI passthrough to `rigel:443`. No inbound ports opened on `rigel` for the public internet directly. See §7 for the config CS IT applied.

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

Replace `<CAMPUS_CIDR>` with the actual BYU campus / VPN subnet (ask CS IT). The public-webhook path arrives via CS IT's HAProxy → `:443`, so no extra firewall rules are needed for internet ingress beyond the campus-CIDR-scoped `:443` rule above.

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

## 7. Public entry via CS IT HAProxy

The only path from the public internet to rigel is CS IT's shared HAProxy doing SNI passthrough on `haproxy1.cs.byu.edu:443 → rigel:443`. GitHub webhooks + the Coolify deploy API arrive that way; everything else on rigel stays VPN-only.

Setup is entirely on the CS IT side — no cloudflared, no tunnel daemon, no inbound rules on rigel beyond the campus-CIDR `:443` allow. Request via a ticket; templates in [`tickets/README.md`](tickets/README.md).

What CS IT applies on their end (for reference / if a rule ever needs debugging):

```
# HAProxy frontend (SSL passthrough — HAProxy never terminates)
frontend ml_capstone_sni
    bind *:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    use_backend ml_capstone if { req_ssl_sni -m end .ml-capstone.cs.byu.edu }
    use_backend ml_capstone if { req_ssl_sni ml-capstone-admin.cs.byu.edu }

backend ml_capstone
    mode tcp
    server rigel rigel.cs.byu.edu:443 send-proxy-v2
```

Verify from anywhere on the public internet:

```bash
curl -I https://ml-capstone.cs.byu.edu/webhooks/source/github/events
# Expect: 405 Method Not Allowed (GitHub POSTs; GET is fine as a reachability check)

curl -I https://ml-capstone-admin.cs.byu.edu/
# Expect: 200 or Coolify login redirect
```

Historical note: the original design used a Cloudflare Tunnel (`cloudflared` on rigel). That was retired 2026-08-07 in favor of the HAProxy path because CS IT already runs HAProxy for other campus services, and it removes an external dependency (Cloudflare account + DNS delegation) that the rest of the classroom stack didn't need.

---

## 8. TLS termination — CS-provided `*.cs.byu.edu` wildcard cert

CS IT issues a DigiCert wildcard for `*.cs.byu.edu` and hands it to us as `fullchain.pem` + `key`. Traefik (inside Coolify) terminates TLS directly from those files. No Let's Encrypt, no DNS-01, no API tokens.

**Cert files on rigel:**

```
/data/coolify/proxy/certs/star_cs_byu_edu.fullchain.pem
/data/coolify/proxy/certs/star_cs_byu_edu.key
```

**Traefik dynamic config** (Coolify UI → Settings → Advanced → Custom Traefik Dynamic Configuration):

```yaml
tls:
  certificates:
    - certFile: /traefik/certs/star_cs_byu_edu.fullchain.pem
      keyFile:  /traefik/certs/star_cs_byu_edu.key
      stores: [default]
  stores:
    default:
      defaultCertificate:
        certFile: /traefik/certs/star_cs_byu_edu.fullchain.pem
        keyFile:  /traefik/certs/star_cs_byu_edu.key
```

Restart Coolify's proxy after wiring the cert in: `docker restart coolify-proxy`.

**Coverage.** The wildcard covers one level under `cs.byu.edu`, so it covers `ml-capstone-admin.cs.byu.edu` (single level) but not two-level names like `<team>.ml-capstone.cs.byu.edu`. Consequences:

- Coolify admin UI, LiteLLM, GitHub webhooks — all get HTTPS.
- Student apps at `<team>.ml-capstone.cs.byu.edu` — serve **HTTP only**. Traffic is still encrypted at the VPN layer, so this is defensible for a classroom. A future two-level wildcard (separate CS IT ticket) would let student apps go HTTPS naturally.

**Renewal.** Cert valid 2026-07-09 → 2027-01-23. Set a mid-January calendar reminder; CS IT will re-issue and hand off new files. Drop them in place and `docker restart coolify-proxy`.

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
8. **Make the App public** (so students can self-install without admin intervention):
   - The App is created as **Private** by default — installable only by the App owner. Students trying to install it will see "This is a private GitHub App" with no button.
   - After creation: sign in as the App owner → https://github.com/organizations/byu-ml-capstone/settings/apps/byu-ml-capstone-coolify → **Advanced** tab (leftmost sidebar of that page) → scroll to red-bordered **Danger Zone** at the bottom → click **"Make this GitHub App public"** → confirm.
   - Verify: incognito window at https://github.com/apps/byu-ml-capstone-coolify should now show an **Install** button, not "private GitHub App."
9. Create the app → generate a **private key** (download the `.pem`).
10. Note the **App ID** and **Client ID**.
11. **Install App** → install it on the class org, "All repositories."

---

## 10. Wire the GitHub App into Coolify

Coolify UI: **Sources → New → GitHub App**. Fill in App ID, Client ID, Client Secret, Webhook Secret, and paste the `.pem` contents. Coolify validates against the GitHub API. Green check = ready.

---

## 11. Team & User Model — self-serve teams via GitHub OAuth

Students sign in via GitHub OAuth, land in a pre-provisioned team, and create their own Projects, Environments, and Applications through the UI. The instructor's ongoing per-student workload is (in the steady state) zero — the term-start provisioning scripts do all the setup.

Rationale: GitHub OAuth eliminates the password-management friction of individual accounts. Students click "Sign in with GitHub" once, no new password. Self-serve is roughly as easy to set up as admin-provisioning would be, but has much better long-term properties (nearly zero ongoing professor workload, higher educational value, matches industry pattern).

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
3. Use `github.com/byu-ml-capstone/hello-world-app` "Use this template" → owner = `byu-ml-capstone`, name = `<team-slug>-<app>`. The org-level `byu-ml-capstone-coolify` App installation already covers the new repo automatically — no per-repo App install step.
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

Under the self-serve model (§11), students DO touch Coolify — just once, during the ~15-minute onboarding lab in [`student-guide.md`](student-guide.md) → Part B → Setup. After that, day-to-day "deploying" is `git push`. What that looks like end-to-end:

1. Student edits code locally on a feature branch, `git push` to their fork/branch on `github.com/byu-ml-capstone/<team-slug>-<app>`.
2. GitHub Actions runs unit tests + docker build on any push. On green, if the branch is `staging` or `main`, Actions fires the corresponding Coolify Deploy Webhook via `curl -X POST`.
3. Coolify pulls, builds, runs the container, then polls `/health`. If `/health` returns 2xx, the new container takes over; otherwise the previous version keeps serving.
4. Student hits their app URL — `<team-slug>-staging.ml-capstone.cs.byu.edu` or `<team-slug>.ml-capstone.cs.byu.edu` — and sees the update.

**When a deploy fails**, students have two feedback channels:

- **GitHub Actions tab** shows unit test / docker build failures immediately (no VPN required to see them). This is the first line of defense — most issues surface here before Coolify gets involved.
- **Coolify Deployments tab** (their team's Application → Deployments) shows Coolify-side failures: build errors, health-check failures, container crashes. Students can read logs themselves; no admin surfacing needed.

**Env vars / secrets** go directly into each Application's **Configuration → Environment Variables** in Coolify. The onboarding lab (student-guide Step 10) walks through this. Repo secrets (webhook URLs, `COOLIFY_API_TOKEN`) live in GitHub Actions secrets; app-runtime secrets (LLM keys, DB creds) live in Coolify env vars — never commit either to the repo.

**GPU access** is opt-in via `docker-compose.yaml` in the student's repo — see §13.

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
2. Revoke the GitHub App's org installation (or leave it — it's harmless when no repos use it).
3. Ask CS IT to disable the HAProxy SNI passthrough for the class hostnames if you want the public entry point closed.
4. `docker compose -f /data/coolify/source/docker-compose.yml down`.
5. Snapshot `/data/coolify` if you want to preserve state.
6. LiteLLM container is independent — leave it or `docker rm -f litellm`.

---

## 17. Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Student push doesn't trigger deploy | GitHub webhook failed, HAProxy dropped the connection, or Actions job never fired the curl | GitHub Actions tab first; then GitHub App → Advanced → Recent Deliveries; then HAProxy diagnostic (see [`troubleshooting.md`](troubleshooting.md) "CS IT HAProxy returns EOF") |
| Build fails with "no space left" | Docker build cache full | Run the prune cron manually |
| All apps 502 | Traefik crashed or Coolify updated mid-request | `docker restart coolify-proxy` |
| TLS cert about to expire | `*.cs.byu.edu` DigiCert expires 2027-01-23 | File CS IT ticket for renewal; drop new files in `/data/coolify/proxy/certs/`; `docker restart coolify-proxy` (§8) |
| LiteLLM unreachable | Container died, or firewall reload dropped rules | `docker ps`; re-apply `ufw allow` lines |
| GPU app fails: "could not select device driver" | NVIDIA Container Toolkit not installed / Docker not restarted | Re-run §4; `systemctl restart docker` |
| GPU app fails: "no such device" or "all GPUs in use" | Another container has claimed all 4 (or TLJH is holding some) | `nvidia-smi` to identify; ask the holder to stop |
| TLJH login fails, "user not found" | SSSD not running or LDAP unreachable | `systemctl status sssd`; `getent passwd <user>`; check qsynology reachability |
| TLJH notebook opens in `/home/jupyter-<user>` not `/home/<user>` | `dirs.home` config lost | `sudo tljh-config set dirs.home /home/{username} && sudo tljh-config reload` |
| `rigel` fully offline | Hardware / network / OS | Coolify + LiteLLM + apps all down until recovery. LLM users can fall back to direct-to-vLLM on castor/pollux — see the admin guide's emergency section |

---

## 18. Why This Design

- **Coolify over Dokku:** students learn the GitHub-webhook workflow that mirrors industry CI/CD.
- **GitHub App (for repo auth) + GitHub OAuth (for Coolify sign-in):** one credential to manage per role, org-scoped, one-click revoke at term end. Students sign in via OAuth (invite-gated by roster) instead of maintaining separate Coolify passwords.
- **Self-serve teams over admin-provisioned Applications:** students click "Sign in with GitHub," land in their pre-provisioned team, and create their own Projects/Environments/Applications. Instructor's ongoing per-student workload drops to near zero, and students learn the real Coolify workflow instead of a stripped-down admin-only view.
- **Coexists with LiteLLM on `rigel`:** LiteLLM is CPU-cheap and needs no GPU. Coolify + LiteLLM + LLM proxy on one box is easier to reason about than two.
- **CS IT HAProxy as the public entry point** (SNI passthrough, `haproxy1.cs.byu.edu:443 → rigel:443`): no cloudflared daemon on rigel, no external Cloudflare dependency, no DNS delegation. Only the GitHub webhook path and the Coolify deploy API are reachable from the internet; everything else stays VPN-only.
- **CS-provided `*.cs.byu.edu` wildcard cert** instead of Let's Encrypt: no ACME challenge dance, no API tokens to rotate. Trade-off: single-level wildcard only, so student apps at `<team>.ml-capstone.cs.byu.edu` serve HTTP (VPN encrypts them anyway).
- **GPUs on `rigel` for student containers:** students can deploy GPU-accelerated apps (inference, small training, media). A6000-per-container is a hard cap — plan a policy before demand outstrips supply.
- **TLJH on the same box:** consolidates the JupyterHub deployment for GPU-heavy classes. Home directories on qsynology mean users see the same files whether they log into `castor`, `pollux`, or `rigel`. Coolify's Traefik terminates TLS for both student apps and TLJH — one cert lifecycle.
