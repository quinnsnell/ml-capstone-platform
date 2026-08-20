# Classroom AI Cluster — Student Setup Guide

Your class has access to a shared **AI + CI/CD cluster** at `ml-capstone.cs.byu.edu`. It gives you two things:

1. **AI coding assistance** — chat and inline autocomplete in your editor, powered by the class's shared GPU cluster (Qwen coder models).
2. **CI/CD platform** — push code to GitHub, run tests in GitHub Actions, and on green tests your app auto-deploys to a URL you can share.

You can use either capability or both. This guide walks you through setting up each.

## Contents

- [Before you start](#before-you-start)
- **Part A — AI coding in your editor**
  - [Option 1: VS Code + Continue (recommended)](#option-1-vs-code--continue-recommended)
  - [Option 2: Continue chat + GitHub Copilot autocomplete](#option-2-continue-chat--github-copilot-autocomplete)
  - [Option 3: Terminal + opencode](#option-3-terminal--opencode)
  - [Option 4: VS Code + GitHub Copilot BYOK](#option-4-vs-code--github-copilot-byok)
- **Part B — Deploying your app via CI/CD**
  - [The overall flow](#the-overall-flow) — architecture diagram + who does what
  - [Why staging + prod?](#why-staging--prod)
  - [Setup: Create your repo, then sign in and create your Coolify Applications](#setup-create-your-repo-then-sign-in-and-create-your-coolify-applications) — the 10-step onboarding lab
  - [Section 1: Build your first deployable app](#section-1-build-your-first-deployable-app) — grow hello-world into a sentiment classifier
  - [Section 2: Test it locally](#section-2-test-it-locally)
  - [Section 3: Add tests](#section-3-add-tests)
  - [Section 4: Make `/health` do the integration test's job](#section-4-make-health-do-the-integration-tests-job)
  - [Section 5: GitHub Actions — the 3-job pipeline](#section-5-github-actions--the-3-job-pipeline)
  - [Section 6: Your testing strategy — the three tiers](#section-6-your-testing-strategy--the-three-tiers)
  - [Section 7: Making your deploys fast (when they get slow)](#section-7-making-your-deploys-fast-when-they-get-slow) — the two-Dockerfile pattern
  - [Section 8: The day-to-day update–test–PR–deploy workflow](#section-8-the-day-to-day-updatetestprdeploy-workflow)
- [Using the classroom LLM from inside your deployed app](#using-the-classroom-llm-from-inside-your-deployed-app)
- [Using a GPU in your app](#using-a-gpu-in-your-app)
- [Persistent storage (databases, uploaded files, anything stateful)](#persistent-storage-databases-uploaded-files-anything-stateful)
- [Troubleshooting](#troubleshooting)
- [Quick reference](#quick-reference)

## Before you start

**Install GlobalProtect and connect to the CS VPN** — the cluster is on the CS network. Only the GitHub webhook + Coolify deploy-API paths are reachable from the public internet (so GitHub Actions can trigger deploys); everything else, including the LLM endpoint and your deployed apps, requires VPN.

- VPN gateway: `cs-vpn.byu.edu`
- Client: GlobalProtect (BYU IT has installers and instructions at vpn.byu.edu) 

Also make sure you have:

- A **GitHub account** — the email you use for GitHub must match the one your instructor has on the class roster. That's how Coolify's login and the org invite find you.
- **Docker installed locally** (for testing your app before pushing)
- **VS Code** or another editor of your choice

Your instructor has already:

- Provisioned you a **Coolify Team** on the classroom cluster (you'll see it after signing in)
- Sent you an **invitation to the `byu-ml-capstone` GitHub organization** — accept it before Step 1 of the Setup section below
- Set up the shared **`byu-ml-capstone-coolify` GitHub App** and **`ml-capstone` deploy server** — nothing for you to install
- Told you the **repo naming convention** — `<yourname>-<appname>` while you're working solo (e.g., `alice-sentiment`, `qsnell-hello-world`), or `<groupname>-<appname>` once you move to the group project (e.g., `group3-recommender`). Whatever you name your repo becomes your deploy hostname prefix — the wildcard DNS `*.ml-capstone.cs.byu.edu` covers anything you pick, so no assignment needed.

All `*.ml-capstone.cs.byu.edu` subdomains resolve internally to the classroom cluster automatically — no `/etc/hosts` tweaking needed as long as you're on the CS VPN.

If DNS resolution doesn't work when you're on VPN, verify with `nslookup <your-repo>.ml-capstone.cs.byu.edu` — it should return an internal `10.x.x.x` address. If it returns NXDOMAIN, your VPN's DNS resolver may be misconfigured; contact your instructor.

---

# Part A — AI coding in your editor

## What you get

Two model aliases exposed by the cluster's LiteLLM proxy:

- `classroom-chat` — chat, refactoring, agentic edits
- `classroom-autocomplete` — inline ghost-text (FIM)

Both aliases stay stable even if your instructor swaps the underlying model.

**Endpoint** (VPN-only): `http://ml-capstone.cs.byu.edu:4000/v1`

## Which client should I use?

Pick whichever you're most comfortable with. If you don't have a preference, **Continue** covers both chat and autocomplete cleanly.

| Client                                  | Chat via cluster | Autocomplete           | Notes                                            |
|-----------------------------------------|------------------|------------------------|--------------------------------------------------|
| **Continue** (VS Code)                  | Yes              | Yes (from cluster)     | Recommended — one extension, both features       |
| **Continue chat + Copilot autocomplete**| Yes              | Yes (from GitHub)      | Keep Copilot's autocomplete if you already like it; use Continue for chat |
| **opencode** (terminal)                 | Yes              | n/a — chat only        | Good for terminal-first workflows                |
| **Copilot BYOK** (VS Code)              | Yes              | Yes (from GitHub)      | Requires Copilot subscription; chat via cluster   |

---

## Option 1: VS Code + Continue (recommended)

Both chat and inline ghost-text come from the classroom cluster in one extension.

### 1. Install Continue

Extensions sidebar (`Cmd+Shift+X` / `Ctrl+Shift+X`) → search **Continue** → Install.

### 2. Disable GitHub Copilot in this workspace (if installed)

Copilot and Continue both draw inline ghost-text and fight over the same slot. In your project's `.vscode/settings.json`:

```json
{
  "github.copilot.enable": { "*": false }
}
```

Then `Cmd+Shift+P` → **Developer: Reload Window**.

(If you'd rather **keep Copilot's autocomplete** and only use Continue for chat, skip this step and use Option 2 instead.)

### 3. Create the Continue config

Continue's UI provider dropdown doesn't expose "OpenAI Compatible", so we configure the classroom endpoint via YAML:

```bash
mkdir -p ~/.continue
code ~/.continue/config.yaml
```

Paste this as the whole file:

```yaml
name: Classroom
version: 0.0.1
schema: v1
models:
  - name: Classroom Chat
    provider: openai
    model: classroom-chat
    apiBase: http://ml-capstone.cs.byu.edu:4000/v1
    apiKey: sk-noauth
    roles:
      - chat
      - edit
      - apply
  - name: Classroom Autocomplete
    provider: openai
    model: classroom-autocomplete
    apiBase: http://ml-capstone.cs.byu.edu:4000/v1
    apiKey: sk-noauth
    roles:
      - autocomplete
    useLegacyCompletionsEndpoint: true
```

Key details:

- `provider: openai` is Continue's shorthand for "any OpenAI-compatible endpoint" once you also set `apiBase`. Not talking to OpenAI's servers.
- `useLegacyCompletionsEndpoint: true` on autocomplete routes to `/v1/completions` (FIM-capable) instead of `/v1/chat/completions`. Required for the FIM tokens to work.
- `name: Classroom` is the **assistant** name (see step 5).

Save. `Cmd+Shift+P` → **Developer: Reload Window**.

### 4. Sign out of Continue Hub if you were auto-signed-in

Fresh Continue installs sign you into Continue Hub and pick a hosted assistant (usually a Claude model). Hub assistants shadow your local `config.yaml`. Sign out from the profile icon at the bottom of the Continue side panel → **Sign out** → reload window. Or close and reopen VS Code entirely.

### 5. Switch to the Classroom assistant and verify

1. Click the Continue extension icon (activity bar, far left).
2. Top of the Continue panel — **Current assistant** should say **Classroom** (click the assistant chip to switch if not).
3. Open the chat panel: `Cmd+L`. The model chip near the input should offer **Classroom Chat** — pick it.
4. Type `"what is 2+2?"`. You should get a response in a few seconds.
5. Open a Python file, place your cursor mid-function, wait ~1s. Ghost-text should appear from **Classroom Autocomplete**.

Both working = you're set.

### If you get stuck

- **Chat panel shows `claude haiku 4.5` or similar** — still on a Hub assistant. Sign out (step 4), reload.
- **Chat sends but nothing comes back** — VPN's off. `curl http://ml-capstone.cs.byu.edu:4000/v1/models` should return JSON; if it fails, fix VPN first.
- **Ghost-text never appears** — Copilot still competing (redo step 2), or `useLegacyCompletionsEndpoint: true` got dropped from your YAML.
- **YAML parse errors** — YAML is whitespace-sensitive; use 2 spaces (no tabs), align `-` under `models:`.

---

## Option 2: Continue chat + GitHub Copilot autocomplete

If you like Copilot's ghost-text and just want the classroom cluster for chat:

1. **Keep Copilot enabled** as normal (don't do step 2 of Option 1).
2. Set up Continue exactly as Option 1, **but change the autocomplete model in `~/.continue/config.yaml`** — remove the `- name: Classroom Autocomplete` block entirely so Continue doesn't try to also do ghost-text. Your YAML has only the Classroom Chat model.
3. In VS Code, both extensions coexist: Copilot handles inline autocomplete (from GitHub's servers), Continue handles the chat panel (from the classroom cluster).

Trade-off: Copilot's autocomplete needs internet access + a Copilot subscription. The classroom cluster's chat is free and stays on VPN.

---

## Option 3: Terminal + opencode

[opencode](https://opencode.ai) is a terminal-based agentic assistant, similar to Claude Code but pointed at any OpenAI-compatible endpoint. Chat-only, no editor autocomplete.

### Install and configure

```bash
curl -fsSL https://opencode.ai/install | bash
```

Create `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "classroom": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Classroom Cluster",
      "options": {
        "baseURL": "http://ml-capstone.cs.byu.edu:4000/v1",
        "apiKey": "sk-noauth"
      },
      "models": {
        "classroom-chat": {
          "name": "Classroom Chat",
          "limit": { "context": 131072 }
        }
      }
    }
  }
}
```

Then run `opencode`. In the TUI, `/models` and pick **Classroom Cluster › Classroom Chat**.

---

## Option 4: VS Code + GitHub Copilot BYOK

If you're already a Copilot user and want to route Copilot Chat to the classroom cluster (while keeping Copilot's autocomplete on GitHub's servers).

**Requirements:** GitHub Copilot + GitHub Copilot Chat extensions, VS Code 1.122+, active Copilot subscription.

### Copilot Chat

`Cmd+Shift+P` → **Chat: Manage Language Models** → pick **OpenAI Compatible** → fill in:

- Base URL: `http://ml-capstone.cs.byu.edu:4000/v1`
- API Key: `sk-noauth`
- Model ID: `classroom-chat`

Save. The model appears in the Copilot Chat picker.

If Copilot Chat hangs on a particular model, set `toolCalling: false` on its entry in `github.copilot.chat.customOAIModels` in VS Code settings.

### Copilot CLI

```bash
export COPILOT_PROVIDER_BASE_URL=http://ml-capstone.cs.byu.edu:4000/v1
export COPILOT_PROVIDER_API_KEY=sk-noauth
export COPILOT_MODEL=classroom-chat
# Optional: air-gapped mode (no telemetry to GitHub):
export COPILOT_OFFLINE=true

copilot
```

Put the exports in `~/.bashrc` (or `~/.zshrc`) to persist.

---

# Part B — Deploying your app via CI/CD

## The overall flow

You'll build a small containerized web app and set up a professional multi-environment CI/CD pipeline. Real-world teams don't push straight to production — they promote through a staging environment first. Here's what we'll build:

```
Local edits on feature branch
    │ git push <branch>
    ▼
GitHub Actions on any push / PR:
    ┌──────────────────────────────────────────┐
    │  [test] unit tests + docker build        │
    │  (GitHub-hosted runner, ~30s)            │
    └──────────────────────────────────────────┘
                     │ green
                     ▼
Open PR into `staging` branch → merge into `staging`

    ┌──────────────────────────────────────────┐
    │  [deploy-staging]                        │
    │    curl Coolify staging webhook          │
    │      → Coolify builds + swaps container  │
    │      → Coolify health check hits /health │
    │        (thorough — see Section 4)        │
    │    → group-1-staging.ml-capstone.cs.byu.edu│
    └──────────────────────────────────────────┘
                     │ Coolify reports healthy
                     ▼
Manual QA — you (or a reviewer) hit the staging URL
                     │ looks good
                     ▼
Open PR from `staging` into `main` → merge into `main`

    ┌──────────────────────────────────────────┐
    │  [deploy-prod]                           │
    │    curl Coolify prod webhook             │
    │      → Coolify builds + swaps            │
    │    → group-1.ml-capstone.cs.byu.edu       │
    └──────────────────────────────────────────┘
```

**What your instructor sets up (once per group at term start):**

- Provisions your Coolify Team + adds you to it (you sign in with your GitHub account — the email must match your roster row)
- Attaches the shared `ml-capstone` deployment server to your team
- Installed the `byu-ml-capstone-coolify` GitHub App on the whole `byu-ml-capstone` org, so it auto-covers any repo you create inside the org — you never install anything on GitHub yourself
- Wildcard DNS `*.ml-capstone.cs.byu.edu` — anything under that name resolves to the cluster

**What you (or your group) does:**

- Accept the `byu-ml-capstone` org invite (see Setup Step 1) and create your class repo from the `hello-world-app` template
- Sign into Coolify and set up your Applications — see **Setup: Create your repo, then sign in and create your Coolify Applications** below (one-time, ~15 min)
- Write your app + Dockerfile + unit tests
- Make your `/health` endpoint thorough enough to double as an automated smoke test (Section 4)
- The 3-job GitHub Actions workflow ships in the template — you just modify it as your app grows (Section 5)
- Follow the branch flow: feature branch → PR to `staging` → PR to `main`

> **Roadmap note.** Automated integration tests running from GitHub Actions against the live staging URL (Vercel-style Preview Deploys with full pytest) require a self-hosted runner inside the CS VPN. That's on the roadmap for once the class grows. For now, Coolify's health check runs as the deploy gate (Section 6, Tier 2), and you run `./integration-test.sh --staging` by hand before promoting to prod (Section 6, Tier 3).

## Why staging + prod?

Real teams never merge straight into production. Staging exists to:

- **Catch bugs that only appear against real infrastructure** — networking, env vars, actual database, real dependencies
- **Let integration tests hit a live URL** — unit tests can't verify "did my LLM prompt actually work end-to-end"
- **Give reviewers something clickable** — before merging to prod, someone visits the staging URL and sanity-checks
- **Provide a rollback safety net** — if prod breaks after a merge, you can roll back knowing staging worked

This mirrors what you'll do at every serious tech company.

## Setup: Create your repo, then sign in and create your Coolify Applications

**Do this once, before writing any code.** ~15 minutes.

You'll:

1. **On GitHub:** accept the `byu-ml-capstone` org invite + create your class repo from the `hello-world-app` template inside the org (**with all branches**)
2. Sign in to Coolify with your GitHub account
3. Find your team and verify the `ml-capstone` server is attached
4. Create a Project containing production + staging Environments
5. Create one Application per Environment (both pointing at your class repo, different branches). While creating each, set **Advanced → Deployment → "Manual deployments only"** so GitHub Actions can gate deploys behind tests. (Optional: enable GPU in the same Advanced tab if your app needs one.)
6. Copy the Deploy Webhook URLs + create an API token, paste into GitHub Actions secrets
7. Push a commit to verify the pipeline works end-to-end

### 1. Accept the org invite + create your class repo under `byu-ml-capstone`

**Do this first — before opening Coolify.** Every Coolify Application you'll create in the later steps is pointed at a GitHub repo, so the repo has to exist first.

Your instructor sent you an invitation to the **[byu-ml-capstone](https://github.com/byu-ml-capstone)** GitHub organization. **You must accept the invitation before you can create your repo inside the org.**

- Check your GitHub notifications (bell icon top right) → look for "You have an invitation to join byu-ml-capstone"
- Or visit https://github.com/orgs/byu-ml-capstone/invitation directly
- Or check your inbox — GitHub also emails the invitation to your primary GitHub email
- Click **Join byu-ml-capstone**

If you can't find the invitation and you're sure the instructor sent it, ask them to re-run `./scripts/invite-to-org.sh --apply` (idempotent — re-sends only for pending users).

You'll create your class repo **inside the org**, not under your personal account. Why: the instructor installed the `byu-ml-capstone-coolify` GitHub App at the org level once, and that installation automatically covers every repo you create inside the org. You never have to install anything on GitHub — Coolify sees your repo as soon as it exists.

**Seed your repo from the `hello-world-app` template:**

- Go to **https://github.com/byu-ml-capstone/hello-world-app**
- Click the green **"Use this template"** button → **"Create a new repository"**
- **Owner:** `byu-ml-capstone` (from the dropdown — NOT your personal account)
- **Repository name:** follow the class convention **`<yourname>-<appname>`** for solo work, or **`<groupname>-<appname>`** once you move to the group project. Examples:
  - Individual sandbox phase: `alice-hello`, `alice-sentiment`, `qsnell-hello-world`
  - Group phase: `group1-sentiment`, `group3-recommender`
  - Your repo name becomes your deploy hostname prefix (thanks to wildcard DNS at `*.ml-capstone.cs.byu.edu`) — e.g., repo `alice-sentiment` → prod at `http://alice-sentiment.ml-capstone.cs.byu.edu`. Pick something you'll want to see in URLs.
- **Public** or **Private** — either works; Private is fine and matches production practice
- ✅ **CHECK the box "Include all branches"**. The template ships with `main` AND `staging` branches; by default GitHub only copies `main`. Without this checkbox you'll need to create `staging` yourself later, and the staging Coolify Application won't have a branch to track.
- Click **Create repository from template**

**Verify both branches copied over.** On your new repo's page, click the branch dropdown (top-left, above the file list) — you should see BOTH `main` and `staging` listed. If you only see `main`, you missed the "Include all branches" checkbox; delete the repo and redo the template step, OR recover by running:

```bash
git clone https://github.com/byu-ml-capstone/<your-repo>.git
cd <your-repo>
git checkout -b staging
git push -u origin staging
```

You now have a fresh repo at `github.com/byu-ml-capstone/<your-repo>` populated with a minimal FastAPI (`/`, `/health`, `/languages`) and the 3-job CI/CD workflow. The `byu-ml-capstone-coolify` App already has access to it — no install step needed.

> **About the workflow:** your repo includes `.github/workflows/ci.yml` — this is the GitHub Actions workflow that runs your tests and triggers Coolify deploys. You don't need to write it (the template already has it), but you should understand it — Section 5 later in this guide walks through the file line by line. For now, just know that any push to `staging` or `main` triggers a workflow run that shows up in the Actions tab on your repo.

**Clone the repo + smoke-test it locally.** Before wiring up Coolify, prove the template actually runs on your machine. This catches Docker/Python setup issues *now* — much easier to debug on your laptop than inside a failing deploy.

```bash
git clone https://github.com/byu-ml-capstone/<your-repo>.git
cd <your-repo>
git branch -a          # should list both main and staging
```

The template ships **three** services in one Docker Compose project (each service self-contained in its own subdirectory):

- `hello/` — the public FastAPI app on port 8000. This is what students grow into their real project.
- `time/` — an internal FastAPI sidecar on port 8001 that returns the current UTC time. Stand-in for the kind of process you'd add later (a worker, a local model server, etc.). Reachable only from `hello`.
- `db` (defined in `docker-compose.yaml`, no subdirectory) — an internal Postgres 16 database with a named-volume-backed data directory that survives restarts. Uses the stock `postgres:16-alpine` image; the app owns the schema and creates it at startup via a FastAPI lifespan hook in `hello/main.py`.

Compose starts all three together. Only `hello` gets a public URL in production; `time` and `db` stay on the internal Docker network. The Postgres data lives on a named volume (`db-data`) that persists across `docker compose down` / redeploys / reboots — see the **Persistent storage** section later in this guide for the full story.

Run the unit tests first. These use FastAPI's `TestClient` to call the routes **in-process** — no containers, no HTTP socket, no network. They import `app` directly from `hello/main.py` and hand it fake requests, so they're fast (<1s). The twelve tests in `hello/tests/test_api.py` cover the greeting endpoints (`/`, `/languages`, `/health`), a mocked `/time` call to the sidecar, three `/notes` tests that mock the `NotesDAO` (list, insert, and 503-on-db-outage), and three `/admin/reset` tests (403 when disabled, calls DAO when enabled, 503 on db outage). All boundaries are mocked so the tests don't need any container running.

```bash
pip install -r hello/requirements.txt httpx pytest
cd hello && pytest -v
# 12 tests pass
cd ..
```

Then start all three services detached via Docker Compose. **Shortcut:** the template ships a `test-local.sh` at the repo root that does exactly the block below (compose up + build, wait for `/health`, curl `/`, `/health`, `/time`, POST + GET `/notes`, print the stop command). Run `./test-local.sh` if you'd rather not type it out. What it does under the hood:

```bash
export SERVICE_FQDN_HELLO=http://localhost:8000   # stubs the compose interpolation

docker compose up -d --build                       # builds AND starts hello + time + db
sleep 5                                            # first postgres boot takes a beat

curl http://127.0.0.1:8000/health
# {"ok":true,"version":"0.1.1"}

curl "http://127.0.0.1:8000/?lang=es"
# {"hello":"Hola, mundo"}

curl http://127.0.0.1:8000/time                    # proves hello -> time sidecar comms
# {"from_time_service":{"utc":"..."}}

curl -X POST http://127.0.0.1:8000/notes \
  -H 'Content-Type: application/json' \
  -d '{"body":"hello persistence"}'                # proves hello -> db round-trip
# {"id":1,"body":"hello persistence","created_at":"..."}

curl http://127.0.0.1:8000/notes                   # reads the row back from the db
# [{"id":1,"body":"hello persistence","created_at":"..."}]
```

Containers keep running — try more curls (`?lang=de`, `?lang=fr`, `/languages`, more POSTs to `/notes`), tail logs with `docker compose logs -f`, or leave them up while you continue setup. When you're done:

```bash
docker compose down                                # stops services; VOLUMES PERSIST
# ...or...
docker compose down -v                             # -v also wipes db-data (nuclear option)
```

If `docker compose up` fails or the endpoints don't respond, fix it here before moving on — a broken local build will also fail in Coolify, just with a slower feedback loop.

**Finding your repo later:** org repos do NOT appear on your personal GitHub profile by default. To find yours:
- **Bookmark it** — the URL is stable: `github.com/byu-ml-capstone/<your-repo>`
- **Org page:** https://github.com/byu-ml-capstone lists every repo you have access to
- **Sidebar chip:** when you're signed in, GitHub shows the `byu-ml-capstone` avatar in the left sidebar of your dashboard — click it to jump to the org
- **Pin it to your profile:** on your repo's page, hover the ⭐ area → the "..." menu offers "Pin repository" — pinned repos DO show on your public profile

### 2. Sign in to Coolify

Get on the BYU VPN, then open **https://ml-capstone-admin.cs.byu.edu** and click **"Sign in with GitHub"**.

**No invite email.** Your instructor has added your email to the class roster ahead of time. When you sign in with GitHub, Coolify sees that your GitHub account's primary email matches the roster row and links you to your pre-provisioned team automatically. If you see "Registration is disabled. Please contact the administrator" after authorizing GitHub, the email on your GitHub account doesn't match the roster — tell your instructor which email to use.

### 3. Find your team + verify the server

The team switcher lives at the top of the main panel — it looks like a breadcrumb, with small up/down arrows next to each segment. Click your team's segment and pick your team from the dropdown (something like `Group 3` or `Alice Sandbox`). Initially, it will only have `Yourname Sandbox`

**Why servers matter.** Every Application you create in Coolify has to be *deployed somewhere*. In cloud-PaaS terms, a "server" is a compute target — the physical or virtual machine that runs your containers. Your team already has one attached, called **`ml-capstone`**. Behind the scenes it's a shared physical box (`rigel.cs.byu.edu`, 4× A6000 GPUs) that hosts every team's containers — but the abstract name `ml-capstone` lets your instructor move workloads to different hardware later without changing anything you see.

Left sidebar → **Servers**. You should see one server called **`ml-capstone`** with a green "reachable" indicator. That's all you need to check — you don't need to click into the server; the details page is admin-oriented. If the server is missing, tell the instructor before continuing.

### 4. Create a Project + Environments

Coolify's structure:

```
Team
  └── Project (e.g., "sentiment-app")
       ├── Environment "production"
       │    └── Application (your app on the prod domain)
       └── Environment "staging"
            └── Application (your app on the staging domain)
```

- Sidebar → **Projects → + New Project**. Name it after your app (e.g., `sentiment-app`).
- Coolify auto-drops you into the default `production` Environment after project creation — you'll see the *environment* page, not the project overview. That's expected, but the **+ New Environment** button lives on the *project* page one level up, not here.
- **Click the project name in the breadcrumb at the top** (e.g., `sentiment-app`) to go back up to the project overview.
- From the project overview → **+ New Environment** → name it `staging`.
- You should now see both `production` and `staging` listed on the project page.

### 5. Create your production Application

Inside your project → click into the **production** Environment → **+ Add Resource**.

You'll see several tiles. Click **GitHub Repo (with GitHub App)** — NOT the similarly-named "Git Repository (with Deploy Key)" tile. Same visual, completely different auth paths:

- **GitHub Repo (with GitHub App)** ← this one — uses the `byu-ml-capstone-coolify` App the instructor installed at the org level. Correct choice.
- **Git Repository (with Deploy Key)** ← *not* this — expects an SSH deploy key you'd have to paste into your repo yourself. Won't pair with the App; deploys will silently fail.

**Screen 1 — Choose a GitHub App.** Pick **`byu-ml-capstone-coolify`** (should be the only one — the instructor's org-level install).

**Screen 2 — Select repository.** Coolify shows every repo the App can see under `byu-ml-capstone` — that list contains every student's repo, so **double-check you pick YOUR repo** (e.g., `byu-ml-capstone/<your-repo>`). Then click **Load Repository**.

**Configuration panel** (appears underneath the repo selector once loaded):

- **Branch**: `main`
- **Build Pack**: **Dockerfile** — reads the `Dockerfile` at the repo root.
- **Port**: `8000` — matches the template's `EXPOSE 8000`. This is the container port Traefik will route your domain to.

Click **Continue** — lands you on the Application's General page.

> **Do you need to set Port Mappings?** No. Port Mappings (further down the General page) bind a specific *host* port to a container port — that's for apps you want to reach directly by port, bypassing the domain/Traefik path. Our setup routes by domain, so the **Port** field you already set is all that's needed.

On the General page, top to bottom:

- **Name**: Coolify auto-generates something ugly like `<your-repo>:main-<longhash>`. Rename it to something readable — e.g., `<your-repo>-prod`. This is only what you see in the Application list; doesn't affect the deploy.
- **Save** the General page.

**Now set the Domain.** Scroll down on the General page to the **Access** section and click the gear icon next to **"1 configured domain"** (or click the **Domains** tab in the Application's left tab bar — same page). Coolify has already auto-created a placeholder domain that looks like `<longhash>.<ip>.sslip.io` — that was Coolify's stopgap while you had no real domain configured. You'll replace it:

- **Add a new domain**:
  - **Protocol**: `http://`
  - **Domain**: `<your-repo>.ml-capstone.cs.byu.edu` — use your actual repo name as the prefix (e.g., repo `alice-sentiment` → `alice-sentiment.ml-capstone.cs.byu.edu`). Wildcard DNS covers whatever you pick.
  - **Port**: `8000` — matches the container's `EXPOSE 8000` from your Dockerfile.
- **Delete the `<longhash>.sslip.io` placeholder** — you don't need it once you have a real domain.
- **Delete `www.<your-repo>.ml-capstone.cs.byu.edu` if Coolify auto-added it** — it does that by default for public sites, but no one's going to type `www.` for a VPN-only internal app. Leaving it just clutters the Domains list.
- **Do NOT click "Generate Domain"** — that button produces another `.sslip.io` URL and can trigger a Coolify UI crash.
- **Save** the Domains configuration.

> **Why HTTP not HTTPS?** The CS wildcard cert covers `*.cs.byu.edu` (one level only), so it doesn't cover the two-level `<your-repo>.ml-capstone.cs.byu.edu` your app lives at. Rather than have every student's browser scream "Not Secure," student apps serve over plain HTTP. Traffic is already encrypted at the VPN layer, so this is safe. A future upgrade to a two-level wildcard cert would make HTTPS work naturally.

Then click the **Advanced** tab:

**Advanced → Deployment.** Two options; pick **Manual deployments only**.

- **Deploy on push (webhooks)** — Coolify redeploys on every push to the tracked branch. Not what we want; GitHub Actions runs tests first and only fires the deploy webhook if they pass.
- **Manual deployments only** ← this one. GitHub Actions will POST to Coolify's Deploy Webhook after tests pass; you shouldn't click the Deploy button by hand.

**Advanced → GPU (optional, ML apps only).** `hello-world-app` doesn't use a GPU — skip this section for the pipeline demo. For apps that use ML models (sentiment-test-app, your own PyTorch/TF workload):

- **Enable GPU** → ON
- **GPU Driver** → `nvidia`
- **GPU Count** → `1` (each container gets one A6000)
- **GPU Device Ids** → your instructor may have assigned your team a specific GPU (`0`, `1`, `2`, or `3`) to spread load across the 4× A6000s on rigel. Set that here. If unset, Docker picks any available GPU.
- **GPU Options** → leave blank

> **Coolify save quirk:** the per-section **Save** buttons in the Advanced tab often DON'T persist changes on their own. After flipping settings, click back to the **General** tab and hit its **Save** button — that's what actually commits your Advanced changes. Verify by refreshing the Advanced tab and checking your settings stuck.

### 6. Create your staging Application

Navigate up to the project (breadcrumb at top) → click into the **staging** Environment → **+ Add Resource → GitHub Repo (with GitHub App)**. Same flow as production, with these differences in the configuration panel:

- **Branch**: `staging` — the branch dropdown should include this option if you ticked "Include all branches" during Step 1's template flow. If it doesn't, you missed the checkbox; see the callout below.
- **Build Pack**: **Dockerfile** (same as production).
- **Port**: `8000` — Coolify does NOT copy this from your production Application; every Application defaults to port 3000. Overriding to 8000 is easy to forget and the deploy will look healthy but the domain returns "Bad Gateway".

> **If the `staging` branch dropdown is missing:** you skipped "Include all branches" when creating your repo. Recover on your laptop:
>
> ```bash
> git clone https://github.com/byu-ml-capstone/<your-repo>.git
> cd <your-repo>
> git checkout -b staging
> git push -u origin staging
> ```
>
> Then click the **Refresh Repository List** button in Coolify's picker and the `staging` branch should appear.

Then on the General page:

- **Name**: rename the auto-generated `<your-repo>:staging-<longhash>` to something readable like `<your-repo>-staging`. Save.
- **Access → gear icon on "1 configured domain"** (or **Domains tab**): add a new domain — protocol `http://`, domain `<your-repo>-staging.ml-capstone.cs.byu.edu`, port `8000`. Delete the `<longhash>.sslip.io` placeholder and the `www.` variant if Coolify added it. Do NOT click "Generate Domain". Save.

Then **Advanced → Deployment → Manual deployments only** (same as production). If your app needs a GPU, configure **Advanced → GPU** the same way — see the settings under Step 5. Remember the save quirk: commit Advanced changes by hitting Save on the **General** tab afterward.

### 7. Grab the Deploy Webhook URLs (in Coolify)

Each Coolify Environment has a Deploy Webhook URL that triggers *just the container swap* (no auto-git-check). GitHub Actions will hit these.

**Still in Coolify** (`https://ml-capstone-admin.cs.byu.edu`), for each of your two Environments:

- In the Environment Resource Settings pannel, click **Webhooks** → find **Deploy Webhook** → copy the URL into a notebook or something you can refer to later.
- Note which one is staging and which is production. You'll paste these into GitHub secrets in Step 9 as `COOLIFY_DEPLOY_WEBHOOK_STAGING` and `COOLIFY_DEPLOY_WEBHOOK_PROD`. Paste them verbatim — no rewriting needed.

### 8. Create a Coolify API token (in Coolify)

The webhook is `deploy`-scoped by itself, but the GitHub Actions job needs a Bearer token to call it.

**Still in Coolify** (not GitHub — Coolify has its own Keys & Tokens page):

- Click the **Coolify** wordmark/logo top-left to go back to the instance dashboard
- Left sidebar → **Keys & Tokens → API Tokens**
- **Description**: `github-actions`
- **Permissions**: check `deploy` only (nothing more; least-privilege)
- **Expiresin**: select 1 year
- **+ Create Token** → copy the token immediately (Coolify shows it exactly once — if you lose it you'll have to make a new one).

### 9. Add three secrets to your GitHub repo (in GitHub)

**Now switch back to GitHub.** Go to your class repo (e.g., `github.com/byu-ml-capstone/<your-repo>`) → **Settings** (repo settings, not org) → left sidebar **Secrets and variables → Actions → New repository secret**. Add all three:

| Secret name | Value |
|---|---|
| `COOLIFY_DEPLOY_WEBHOOK_STAGING` | Deploy Webhook URL from the staging Application (paste verbatim from Coolify) |
| `COOLIFY_DEPLOY_WEBHOOK_PROD` | Deploy Webhook URL from the production Application (paste verbatim from Coolify) |
| `COOLIFY_API_TOKEN` | The `deploy`-scoped token you just created |

Use these exact names — the `.github/workflows/ci.yml` file that shipped with the `hello-world-app` template already references them, so if you spell them right you won't have to edit the workflow.

### 10. Prove the pipeline: make a real code change (and see tests catch a bug)

You've configured everything. Time to make a real code change from your laptop and watch it flow through GitHub Actions → Coolify → your live URL. This walkthrough includes an intentional test failure — that's the point, and you'll see WHY the tests-gate-deploy pattern matters.

**Prep — clone your repo locally.**

```bash
git clone https://github.com/byu-ml-capstone/<your-repo>.git
cd <your-repo>
git branch -a
```

You should see both `main` and `staging` (assuming you ticked "Include all branches" in Step 1). If `staging` is missing:

```bash
git checkout -b staging
git push -u origin staging
git checkout main
```

**Step A — First push: bump the version on `staging` to trigger your first deploy.**

Nothing has been deployed yet — you set Coolify to "Manual deployments only" and haven't pushed anything, so both live URLs currently return connection errors or a Coolify 404 page. This first push establishes the baseline: a clean version bump that passes tests and deploys.

```bash
git checkout staging
```

Open `hello/greetings.py` in your editor (`code hello/greetings.py`, `vim hello/greetings.py`, etc.). Find the version line and bump it:

```python
APP_VERSION = "0.1.1"    # change this
APP_VERSION = "0.1.2"    # to this
```

Save. Commit + push:

```bash
git add hello/greetings.py
git commit -m "v0.1.2: initial staging deploy"
git push
```

Open `https://github.com/byu-ml-capstone/<your-repo>/actions` in a browser. Watch:
- **`test` job** — passes (~30s). A version bump doesn't break any tests.
- **`deploy-staging` job** — fires the Coolify Deploy Webhook (~5s).

Then flip to Coolify → your staging Application → **Deployments** tab. New deployment appears within ~10s: pull → build → healthcheck → healthy. Total ~30-60s end-to-end.

Verify staging is live:

```bash
curl -s http://<your-repo>-staging.ml-capstone.cs.byu.edu/health && echo
# {"ok":true,"version":"0.1.2"}
```

Prod hasn't been deployed yet (`curl http://<your-repo>.ml-capstone.cs.byu.edu/health` still errors) — you'll deploy prod at the end via the staging → main merge. That's how you always want prod to work: nothing goes there without going through staging first.

**Step B — Second push: change the app's BEHAVIOR without updating the test.**

Now demonstrate the tests-gate-deploy pattern. You'll change what the app *does* without updating the test that pins its behavior, and watch the pipeline block the deploy. Open `hello/greetings.py` again and make TWO changes:

1. **Bump the version** again:
   ```python
   APP_VERSION = "0.1.2"    # change this
   APP_VERSION = "0.1.3"    # to this
   ```

2. **Change the Spanish greeting** in the `GREETINGS` dict:
   ```python
   "es": "Hola, mundo",                    # change this
   "es": "¡Buenos días, mundo!",            # to this
   ```

Save. Verify your diff shows exactly two changes:

```bash
git diff hello/greetings.py
```

**Step C — Commit + push. Deliberately do NOT update the tests yet.**

```bash
git add hello/greetings.py
git commit -m "v0.1.3: update Spanish greeting"
git push
```

**Step D — Watch GitHub Actions FAIL. This is correct behavior.**

New workflow run appears in the Actions tab within seconds. Watch:

- **`test` job** runs → **fails** with an AssertionError:
  ```
  test_hello_spanish
  AssertionError: assert {'hello': '¡Buenos días, mundo!'} == {'hello': 'Hola, mundo'}
  ```
- **`deploy-staging` job** never runs — because the test failed, GitHub Actions skips it. Your staging URL still returns `0.1.2` (the version from your Step A deploy).

**This is the whole point of the tests-gate-deploy pattern.** Your test asserted "the Spanish greeting must be `Hola, mundo`" — a contract. You changed the behavior without updating the contract. In production, you'd have shipped a lie. The test caught it BEFORE it went live.

You now have two options:

- **The change was wrong** → revert the code change and push again
- **The change was intentional** → update the test to match the new expected behavior (this is what you'll do next)

**Step E — Fix the test to match the new behavior.**

Open `hello/tests/test_api.py` in your editor. Find `test_hello_spanish`:

```python
def test_hello_spanish():
    r = client.get("/", params={"lang": "es"})
    assert r.status_code == 200
    assert r.json() == {"hello": "Hola, mundo"}       # change this
    assert r.json() == {"hello": "¡Buenos días, mundo!"}  # to this
```

Save. Verify locally:

```bash
cd hello && python3 -m pytest tests/ -v && cd ..
```

All 5 tests should now pass locally.

**Step F — Commit the test fix + push.**

```bash
git add hello/tests/test_api.py
git commit -m "test: update Spanish assertion to match v0.1.3 greeting"
git push
```

**In real life** you'd usually combine Steps B and E into a single commit — the code change and its test update belong together. We split them here to demonstrate the failure mode.

**Step G — Watch GitHub Actions succeed + Coolify deploy.**

New workflow run on GitHub Actions:
- **`test` job** — green (~30s)
- **`deploy-staging` job** — green (~5s), fires the Coolify webhook

Open the Coolify staging Application → **Deployments** tab. New deployment appears within ~10s: pull → build → healthcheck → healthy. Total ~30-60s.

**Step H — Verify staging deployed at 0.1.3. Prod still hasn't received its first deploy.**

```bash
curl -s http://<your-repo>-staging.ml-capstone.cs.byu.edu/health && echo
curl -s "http://<your-repo>-staging.ml-capstone.cs.byu.edu/?lang=es" && echo
curl -s http://<your-repo>.ml-capstone.cs.byu.edu/health && echo
```

Expected:
```
{"ok":true,"version":"0.1.3"}
{"hello":"¡Buenos días, mundo!"}
<connection error or Coolify 404 page — prod has never been deployed>
```

Staging has the new behavior; prod is untouched. This is exactly how a staging environment protects prod: you get to try changes in an environment that mirrors prod without customer impact. Now merge to main to fire prod's first deploy.

**Step I — Promote staging → main (production).**

```bash
git checkout main
git pull
git merge staging
git push
```

Watch Actions run again — this time `deploy-prod` fires instead of `deploy-staging` (the workflow gates them on branch name).

**Step J — Verify prod deployed.**

```bash
curl -s http://<your-repo>.ml-capstone.cs.byu.edu/health && echo
curl -s "http://<your-repo>.ml-capstone.cs.byu.edu/?lang=es" && echo
```

Both should now return the 0.1.3 responses. **Your entire pipeline is proven end-to-end.** Everything after this is code — you know how the mechanics work.

**Debugging failures during this walkthrough:**

- **GitHub Actions red on `test` job** — usually intentional (Step D above). Update your test to match your code change (Step E) OR revert the code change if it was a mistake.
- **GitHub Actions red on `deploy-staging` or `deploy-prod`** — the curl failed. Two common causes:
  - `curl: The requested URL returned error: 405` → your workflow file has `curl` without `-X POST`. See `.github/workflows/ci.yml` — the deploy job should call `curl -fsSL -X POST "..."`.
  - `curl: (6) Could not resolve host: ...` → the DNS record for that hostname isn't reachable from GitHub Actions' runners. Check with the instructor.
- **Coolify Deployments panel shows a red deploy** — click into it, read the build log. Common: Dockerfile references a file you didn't commit; `EXPOSE` port doesn't match Coolify's Port setting; container binds `127.0.0.1` instead of `0.0.0.0`.
- **502 Bad Gateway on the live URL** — container is still starting (wait 30s), or crashed on startup (check Coolify container logs).
- **Live URL returns old version** — Coolify built but didn't swap containers, OR your browser cached. Hard refresh (Cmd/Ctrl+Shift+R), then check the Deployments log to confirm a new container was started.
- **`curl` returns `Found` but browser shows JSON** — Coolify's Traefik is 302-redirecting `http://` to `https://`. Your Application's Domain still starts with `https://` or Force HTTPS is on (Advanced tab). Fix per Step 5's note.

## Section 1: Build your first deployable app

**The trajectory:** you started from `hello-world-app` (2 endpoints, no ML). By the end of this section, you'll have grown it into an LLM-backed sentiment classifier — structurally like the reference `byu-ml-capstone/sentiment-test-app`, which you can peek at whenever you want to see "what does this look like when it's done?" You're not going to fork sentiment-test-app; you're going to *build up to it*, one file at a time, so you understand every piece.

Same repo, same Applications, same domain as your hello-world deploy — you just replace the code inside your existing class repo (`byu-ml-capstone/<your-repo>` or however you named it). Coolify redeploys on your next push automatically.

### 1a. Start from your existing repo (don't create a new one)

You already have a Coolify Application wired to your class repo. Reuse it — replace the code in your existing repo rather than creating a fresh one. That way the Deploy Webhook URLs, secrets, and domain all stay the same.

```bash
cd path/to/<your-repo>          # wherever you cloned it during Setup Step 10
git checkout staging
# You'll make all the changes on staging, test them, then merge to main.
```

### 1b. Replace the code with a sentiment classifier

You can delete `hello/greetings.py`, `hello/main.py`, and `hello/tests/test_api.py` from the template — you'll replace them entirely with what's below. Keep `hello/Dockerfile`, `hello/requirements.txt`, `hello/conftest.py`, and the repo-root orchestration files (`docker-compose.yaml`, `docker-compose.override.yml`, `.github/workflows/ci.yml`, `test-local.sh`). Those stay the same shape; only the code inside `hello/` changes.

You can also delete the `time/` sidecar entirely if you don't need it — it's just a stand-in to demonstrate the multi-service pattern. If you delete it, remove the `time:` service and the `hello.depends_on.time` block from `docker-compose.yaml`, and drop the `/time` endpoint + its test from `hello/`. Or leave it as a reference for when you *do* want to add a real sidecar (Postgres, Redis, a local model server).

### 1c. Write `hello/main.py`

A FastAPI service with four endpoints:

- `GET /ready` — cheap "am I alive?" — no dependencies exercised.
- `GET /gpu` — introspects the container's GPU visibility (helps you verify Coolify's GPU config actually attached one).
- `GET /health` — deep check; Coolify polls this after each deploy and rolls back if it's not 200.
- `POST /analyze` — the real feature; classifies text via the classroom LLM.

```python
"""Small sentiment-classifier via the classroom LiteLLM.

GET  /ready    -> { "ready": true }                    # cheap liveness
GET  /gpu      -> { device info }                       # GPU introspection
GET  /health   -> { "ok": true, "litellm": "<url>" }    # deep health (extended in Section 4)
POST /analyze  { "text": "..." }
  -> { "text", "sentiment": positive|negative|neutral, "confidence", "reasoning" }

Config via environment variables (never hardcode):
  LITELLM_URL      default http://ml-capstone.cs.byu.edu:4000/v1
  LITELLM_API_KEY  default sk-noauth
  MODEL            default classroom-chat
"""
import json
import os
import re
from typing import Literal

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

LITELLM_URL = os.environ.get("LITELLM_URL", "http://ml-capstone.cs.byu.edu:4000/v1").rstrip("/")
LITELLM_API_KEY = os.environ.get("LITELLM_API_KEY", "sk-noauth")
MODEL = os.environ.get("MODEL", "classroom-chat")

app = FastAPI(title="Sentiment via LiteLLM")


class AnalyzeRequest(BaseModel):
    text: str


class AnalyzeResponse(BaseModel):
    text: str
    sentiment: Literal["positive", "negative", "neutral"]
    confidence: float
    reasoning: str


SYSTEM_PROMPT = (
    "You classify the sentiment of user-provided text. "
    'Respond with ONLY a compact JSON object: '
    '{"sentiment": "positive"|"negative"|"neutral", '
    '"confidence": 0.0-1.0, "reasoning": "one short sentence"}. '
    "No prose outside the JSON. No code fences."
)


def _extract_json(content: str) -> dict:
    content = content.strip()
    if content.startswith("```"):
        content = re.sub(r"^```(?:json)?\s*|\s*```$", "", content, flags=re.MULTILINE)
    m = re.search(r"\{.*\}", content, flags=re.DOTALL)
    if not m:
        raise ValueError(f"no JSON in: {content[:200]}")
    return json.loads(m.group(0))


@app.get("/ready")
def ready():
    """Cheap liveness check. Proves the Python process is up and accepting HTTP.

    Deliberately does NOT touch the LLM, GPU, or any I/O. Use this from external
    monitors that just want "is the container alive" without incurring a real
    LLM call every 30 seconds.
    """
    return {"ready": True}


@app.get("/gpu")
def gpu():
    """GPU introspection — reports what CUDA devices this container can see.

    This one is a debugging tool for YOU. When Coolify's Advanced-tab GPU
    config is right, `cuda_available` is true and `devices` lists the A6000(s)
    your container was granted. If `cuda_available` is false but you expect a
    GPU, the container isn't seeing one — check Coolify's Advanced → GPU
    settings (Setup Steps 5–6) and that torch was installed with CUDA support.
    """
    info = {"torch_installed": False, "cuda_available": False, "devices": []}
    try:
        import torch
        info["torch_installed"] = True
        info["torch_version"] = torch.__version__
        info["cuda_available"] = torch.cuda.is_available()
        if torch.cuda.is_available():
            info["device_count"] = torch.cuda.device_count()
            info["devices"] = [
                {
                    "index": i,
                    "name": torch.cuda.get_device_name(i),
                    "memory_total_gb": round(
                        torch.cuda.get_device_properties(i).total_memory / (1024**3), 1
                    ),
                }
                for i in range(torch.cuda.device_count())
            ]
    except ImportError:
        pass  # torch not installed — that's fine for a pure-LLM app
    return info


@app.get("/health")
def health():
    """Deep health check. Coolify polls this after every deploy.

    Currently shallow — just reports config. In Section 4 you'll extend this
    to actually call the LLM so a broken LLM path fails the deploy instead of
    shipping a container that returns 500 on every /analyze.
    """
    return {"ok": True, "litellm": LITELLM_URL, "model": MODEL}


@app.post("/analyze", response_model=AnalyzeResponse)
def analyze(req: AnalyzeRequest):
    with httpx.Client(timeout=30.0) as client:
        r = client.post(
            f"{LITELLM_URL}/chat/completions",
            headers={"Authorization": f"Bearer {LITELLM_API_KEY}"},
            json={
                "model": MODEL,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": req.text},
                ],
                "max_tokens": 200,
                "temperature": 0.1,
            },
        )
    if r.status_code != 200:
        raise HTTPException(502, f"LiteLLM {r.status_code}: {r.text[:400]}")
    content = r.json()["choices"][0]["message"]["content"]
    parsed = _extract_json(content)
    return AnalyzeResponse(
        text=req.text,
        sentiment=parsed["sentiment"],
        confidence=float(parsed.get("confidence", 0.0)),
        reasoning=parsed.get("reasoning", ""),
    )
```

Key patterns to notice:

- **Three health-ish endpoints, three purposes.** `/ready` = "process is up" (cheap, safe to hit every second). `/gpu` = "what hardware did I get?" (debugging). `/health` = "is the whole thing actually working?" (Coolify's deploy gate — Section 4 makes it deep). Separating them lets each caller pay only for what it needs.
- **`os.environ.get("LITELLM_URL", "default")`** — reads the LLM URL from an env var. Never hardcode it. Different envs (local, prod) supply different values.
- **`app.run(host="0.0.0.0")`** happens inside the container via uvicorn (see Dockerfile) — binding to loopback would make the container unreachable from Coolify's proxy.
- **`import torch` inside the endpoint, not at module top.** If you haven't installed torch yet (Section 1 doesn't — it's optional), `/gpu` still returns a valid JSON response saying `torch_installed: false` instead of crashing app startup. Deferred imports keep optional dependencies optional.

### 1d. Write `requirements.txt`

```
fastapi==0.115.6
uvicorn[standard]==0.34.0
httpx==0.28.1
pydantic==2.10.5
```

### 1e. Write the `Dockerfile`

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health').read()" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Two Dockerfile gotchas that trip most students:

1. **Must listen on `0.0.0.0`, not `127.0.0.1`.** Inside a container, binding to loopback means nothing outside the container can reach you. That's `--host 0.0.0.0` in the uvicorn command.
2. **`EXPOSE 8000`** matches the port Coolify's proxy expects. Your instructor's Application config maps their internal port to yours; the convention is `:8000`.

### 1f. Write a `.gitignore`

```gitignore
__pycache__/
*.pyc
.venv/
venv/
.env
.env.local
.pytest_cache/
```

### 1g. Add a `.env` for local development

Create a file called `.env` with:

```
LITELLM_URL=http://ml-capstone.cs.byu.edu:4000/v1
LITELLM_API_KEY=sk-noauth
MODEL=classroom-chat
```

Note the `.env` is **git-ignored** — never commit it, even though this file doesn't have real secrets. It's the pattern; real secrets should also live in `.env` files or your platform's secret store.

## Section 2: Test it locally

Before adding tests or CI, make sure the app actually runs on your machine. Put your `.env` at the **repo root** (not inside `hello/`) — Docker Compose auto-picks up `.env` from the project root and the variables become available to all services.

```bash
docker compose up -d --build   # builds hello/ (and any sidecars), starts detached
```

In another terminal (or after a `sleep 3`):

```bash
curl http://127.0.0.1:8000/health
# {"ok":true,"litellm":"http://ml-capstone.cs.byu.edu:4000/v1","model":"classroom-chat"}

curl -X POST http://127.0.0.1:8000/analyze \
  -H 'Content-Type: application/json' \
  -d '{"text":"I loved the movie, it was fantastic!"}'
# {"text":"...","sentiment":"positive","confidence":0.98,"reasoning":"..."}
```

You must be on VPN for the container to reach the LLM. Stop with `docker compose down` when done.

## Section 3: Add tests

Create `hello/tests/test_health.py`:

```python
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_health_returns_ok():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert "litellm" in body


def test_analyze_requires_text():
    r = client.post("/analyze", json={})
    assert r.status_code == 422  # pydantic validation error
```

`from main import app` works because `hello/conftest.py` marks `hello/` as pytest's rootdir — pytest auto-adds it to `sys.path`, so `main.py` is importable directly.

Add pytest to `hello/requirements.txt`:

```
pytest==8.3.4
```

Run locally from the `hello/` directory:

```bash
cd hello
pip install -r requirements.txt
pytest -v
cd ..
```

Two tests pass. Note that we don't hit the real LLM in unit tests — that would fail in CI where there's no VPN. Real integration tests belong in a separate suite that only runs against a deployed instance.

## Section 4: Make `/health` do the integration test's job

Unit tests (Section 3) verify functions in isolation. Real integration tests — hitting the live deployed URL with real requests — are what catch bugs that only show up against real infrastructure (networking, env vars, actual LLM). Those normally run in CI against staging.

**In the full setup we're aiming for**, a self-hosted GitHub Actions runner inside the CS VPN runs pytest against `http://<your-group>-staging.ml-capstone.cs.byu.edu` on every staging deploy. That runner doesn't exist yet — it's on the roadmap.

**Right now**, Coolify's built-in health check fills the role. Coolify polls your `/health` endpoint after every deploy. If it doesn't return 2xx within N attempts, Coolify marks the deploy as failed and rolls back. You can make that health check as thorough as you want — including verifying the LLM path end-to-end.

### Extend `/health` to exercise the real dependencies

Update `hello/main.py` — replace the simple `/health` with a thorough version that actually calls the LLM:

```python
@app.get("/health")
def health():
    """Deep health check — verifies LLM dependency actually works end-to-end.

    Returns 200 only if:
      - the app is up
      - the LiteLLM endpoint is reachable
      - a small chat request succeeds
      - the response has expected structure
    """
    try:
        with httpx.Client(timeout=10.0) as client:
            r = client.post(
                f"{LITELLM_URL}/chat/completions",
                headers={"Authorization": f"Bearer {LITELLM_API_KEY}"},
                json={
                    "model": MODEL,
                    "messages": [{"role": "user", "content": "healthcheck"}],
                    "max_tokens": 5,
                },
            )
        r.raise_for_status()
        r.json()["choices"][0]["message"]["content"]   # will KeyError if malformed
    except Exception as e:
        raise HTTPException(503, f"health check failed: {e}") from e

    return {
        "ok": True,
        "litellm": LITELLM_URL,
        "model": MODEL,
    }
```

Now when Coolify polls `/health`:
- If your container is up but LiteLLM is unreachable → `/health` returns 503 → Coolify marks deploy unhealthy
- If LiteLLM responds but with garbage → same
- Only if the full chain works does deploy succeed

This is a valid engineering pattern — treating your health check as a live integration test. Trade-off: `/health` now costs a small LLM call per poll (Coolify defaults to every ~30s), so keep the token budget tiny.

### Why keep `/ready` separate

You already have `/ready` from Section 1 — cheap, no I/O, just proves the process is up. Now that `/health` costs a real LLM call per poll, the separation matters:

- **`/ready`** — external liveness monitors ("is the container alive?") can hit this every second without generating LLM load.
- **`/health`** — Coolify's deploy gate ("does the full chain actually work?") gets called only after each deploy, so the LLM cost is one-time-per-release, not per-request.

Some Coolify configurations let you point liveness at `/ready` and the deep readiness check at `/health` explicitly; the default single-endpoint mode uses `/health`, which is what the template's Dockerfile HEALTHCHECK does.

## Section 5: GitHub Actions — the 3-job pipeline

**Your repo already has `.github/workflows/ci.yml`** — you inherited it from the `hello-world-app` template in Setup Step 1. This section walks through what it does so you understand the mechanics (and can modify it later). The current file looks like this:

```yaml
name: CI/CD

on:
  push:
    branches: [main, staging]
    paths-ignore:
      - '**/*.md'
      - '.gitignore'
      - '.dockerignore'
  pull_request:
    branches: [main, staging]
    paths-ignore:
      - '**/*.md'
      - '.gitignore'
      - '.dockerignore'

jobs:
  # Job 1 — unit tests. Runs on every push and every PR.
  # GitHub-hosted runner (public internet) is fine because unit tests don't hit VPN.
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4.2.2
      - uses: actions/setup-python@v5.4.0
        with:
          python-version: "3.12"
          cache: pip
      - name: Install dependencies
        run: pip install -r hello/requirements.txt httpx pytest
      - name: Unit tests
        run: cd hello && pytest tests/ -v

  # Job 2 — deploy to STAGING. Runs after tests pass, only on push to `staging`.
  # Coolify runs its /health check post-deploy; if /health fails, staging deploy fails.
  deploy-staging:
    needs: test
    if: github.ref == 'refs/heads/staging' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Coolify staging deploy
        run: |
          curl -fsSL -X POST "${{ secrets.COOLIFY_DEPLOY_WEBHOOK_STAGING }}" \
            -H "Authorization: Bearer ${{ secrets.COOLIFY_API_TOKEN }}"

  # Job 3 — deploy to PROD. Runs after tests pass, only on push to `main`.
  # By convention, you push to main by merging a PR from staging (which is
  # already deployed + verified via manual QA on the staging URL).
  deploy-prod:
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Coolify prod deploy
        run: |
          curl -fsSL -X POST "${{ secrets.COOLIFY_DEPLOY_WEBHOOK_PROD }}" \
            -H "Authorization: Bearer ${{ secrets.COOLIFY_API_TOKEN }}"
```

### What each piece does

**`on:` block** — the trigger. Any push to `main` or `staging`, and any pull-request targeting them, kicks off a workflow run. `paths-ignore` excludes docs-only or config-only changes so a README typo doesn't burn a deploy.

**Job 1 — `test`.**

- Runs on **every** push and PR, regardless of branch.
- Installs Python + the `hello/` service's dependencies (`pip install -r hello/requirements.txt httpx pytest`), then runs `pytest` from inside `hello/`. `httpx` is added on top because FastAPI's `TestClient` needs it, and `pytest` because it's a dev-only tool that doesn't belong in the app's `requirements.txt`.
- If you add more services with their own tests (e.g. a `time/tests/` directory), add another install + pytest step for each — same pattern.
- Consider adding a `docker compose build` step to catch Dockerfile bugs before deploy — cheap, and reveals problems that pip-installed pytest can't.
- Uses GitHub-hosted runners (Ubuntu) — public internet, so unit tests can't hit the VPN-only classroom LLM (and won't have a GPU either). Keep unit tests offline: mock the network call, use FastAPI dependency overrides, OR add an env-guarded short-circuit in your app so tests can skip the expensive path. The reference `sentiment-test-app` uses the latter pattern — its code checks `SKIP_LOCAL_MODEL=1` and skips loading the ~500 MB local HuggingFace pipeline during CI (see its `main.py` / `config.py`). Your own code has to opt in — the env var doesn't do anything unless you check it.

**Job 2 — `deploy-staging`.**

- Only runs on pushes (not PRs) to the `staging` branch.
- `needs: test` — if tests failed, this never fires. This is the tests-gate-deploy pattern; it's what protects prod from broken code.
- Uses two secrets you configured in Setup Step 9: `COOLIFY_DEPLOY_WEBHOOK_STAGING` (the URL to POST to) and `COOLIFY_API_TOKEN` (the Bearer token in the Authorization header).
- The `curl -X POST` triggers Coolify to pull latest from the `staging` branch, rebuild the container, swap it in.

**Job 3 — `deploy-prod`.**

- Only runs on pushes (not PRs) to the `main` branch.
- Same tests-gate-deploy protection.
- Uses `COOLIFY_DEPLOY_WEBHOOK_PROD` + `COOLIFY_API_TOKEN`.
- Typical path: PR from `staging` → `main`, merge, this fires.

### Where the workflow lives + how to see runs

- File: `.github/workflows/ci.yml` in your repo. Edit it like any other file: local checkout, commit, push.
- Runs history: **Actions** tab on your repo's GitHub page.
- Individual failed job: click the run → click the failed job → expand the step → read stderr. Most failures are self-explanatory.
- Manual re-run: top-right of a failed run → **Re-run failed jobs**.

### Common customizations

- **Add another test suite:** append another `- run:` line inside the `test` job's `steps`. Runs in the same runner container as the pytest step.
- **Only run tests on some paths:** add a `paths:` filter under `on: push:`. Useful once you have big non-code directories that shouldn't trigger CI.
- **Add a linter:** add a step like `- run: pip install ruff && ruff check .` before `pytest`. `ruff` is fast and catches Python style issues.
- **Notify Slack on failure:** add a `- if: failure()` step at the end of a job that curls a Slack webhook. Out of scope here but common at real companies.

Bigger changes (multi-repo builds, matrix testing, custom runners) — GitHub's [Actions documentation](https://docs.github.com/en/actions) is the authoritative reference.

### 5a. Verify your repo secrets are set

You should already have three secrets set from Setup Step 9:
`COOLIFY_DEPLOY_WEBHOOK_STAGING`, `COOLIFY_DEPLOY_WEBHOOK_PROD`, and
`COOLIFY_API_TOKEN`. Confirm they're present at **GitHub repo → Settings →
Secrets and variables → Actions**. Missing any of them → back to Setup Step 9.

### 5b. Push and watch the pipeline light up

Your repo already has both `main` and `staging` branches (from the template) and the remote is already set (you cloned it in Setup Step 10). Push to `staging` first — you replaced hello-world's code with sentiment code, so this is a big change and staging is where big changes should land first:

```bash
git checkout staging
git add .
git commit -m "replace hello-world with sentiment classifier"
git push
```

Watch:

1. **GitHub Actions tab** → CI/CD workflow runs. Job graph shows `test` → `deploy-staging`.
2. **Coolify UI** — your staging Application shows a new deployment.
3. `curl http://<your-repo>-staging.ml-capstone.cs.byu.edu/health` returns your new `/health` JSON (VPN required).

When staging looks good, promote to prod exactly like the Setup Step 10 walkthrough taught you — PR from `staging` into `main` (or merge locally + push), and `deploy-prod` fires.

## Section 6: Your testing strategy — the three tiers

You now have a working pipeline. That raises a real question: *"how do I actually know my app works?"* The classroom setup has three distinct testing layers, each catching different classes of bugs at different times. Understanding the mental model matters more than any single tool.

### The three tiers at a glance

| Tier | Tool | When | Scope | Reachable from |
|---|---|---|---|---|
| **Pre-push** | `./test-local.sh` | Before every `git push` | One app | Your laptop |
| **Deploy gate** | Coolify's `/health` check | After each deploy, gates the swap | One app, against real prod dependencies | Coolify itself, on rigel |
| **Integration** | `./integration-test.sh` | After staging deploys, before merging to prod | One app, against live deployed URL, with real data + edge cases | Your laptop |

There's also a cluster-wide `smoke-test-cluster.sh` your instructor runs to check whole-cluster health — you don't need it day-to-day.

### Tier 1 — Pre-push local (`test-local.sh`)

Runs on your laptop. Builds the container from your current code, starts it, runs the `pytest` suite inside the container, hits every endpoint. Catches syntax errors, broken imports, obvious logic bugs, and "did I forget to update the Dockerfile" mistakes before you push code that would fail in CI.

Fast feedback loop: green here means you're safe to push. Roughly 30 seconds after the initial image is built.

**Limits:** doesn't test against real infrastructure — the `/health` and `/analyze` endpoints hit the classroom LiteLLM, but everything is running locally on your Mac. Bugs that only appear in the Coolify environment (env vars, GPU allocation, networking) can slip through.

### Tier 2 — Deploy gate (Coolify's `/health` check)

Not something you run — it runs automatically as part of every deploy. After Coolify builds and starts your container, it polls your `/health` endpoint. If `/health` returns 503, Coolify marks the deploy unhealthy and keeps serving from the old container. If it returns 200, the new container takes over.

The trick you learned in Section 4: make `/health` do a real deep check. It calls the LLM, runs a sample through the local model, verifies both succeed. That's an actual integration test running inside the deploy pipeline — the deploy literally cannot succeed if the app can't reach its real dependencies.

**Limits:** it's a single scripted check. It doesn't try 50 different inputs, look at response shapes across a variety of cases, or verify edge cases. It answers "does this container basically work?" — not "does this container behave correctly on the range of inputs my users will send?"

### Tier 3 — Integration testing (`integration-test.sh`)

This is what fills the gap between Tier 2 (basic smoke) and full production coverage. It runs on your laptop after a staging deploy and hits the live staging URL with real data:

- Happy paths — positive, negative, neutral text; both models agree; sensible confidence scores
- Edge cases — empty text (should 422), unicode + emoji, very long text (~1500 chars), quotes and HTML in input, punctuation-only input
- Response-shape contract testing — every response has all required fields, confidence values are in [0, 1], sentiment values are in the allowed enum
- Optional stress — concurrent requests, throughput measurement

`integration-test.sh` is bundled with `sentiment-test-app` — check that repo for the actual script. Copy it into your own group's repo, edit the URL default and the test cases to match your app, and use it as your promotion gate.

Green here means: your staging deploy handles the diverse real inputs your users will send, not just the happy path. **Safe to promote from staging to main.**

Sample output:

```
integration-test.sh   target=http://group-1-staging.ml-capstone.cs.byu.edu
────────────────────────────────────────────────────────────────────────────

Basic contract
  PASS  /ready returns 200 with ready=true                       41ms
  PASS  /gpu returns valid structure                             38ms
  PASS  /health returns 200 with llm.ok and local.ok            348ms

Sentiment correctness
  PASS  positive: enthusiastic short (both → positive)         409ms
  PASS  negative: complaint short (both → negative)            439ms
  ...

Robustness
  PASS  /analyze without text returns 422                        32ms
  PASS  /analyze handles unicode + emoji (both → positive)     435ms
  ...

────────────────────────────────────────────────────────────────────────────
13 checks  13 passed  0 failed

Green across the board — safe to promote to main.
```

### What makes a good integration test?

A few principles you'll see in real production integration test suites:

**Test the contract, not the implementation.** Your integration tests should say "given input X, response has field Y with type Z." They shouldn't care how `main.py` is structured. If a colleague refactors `classify_llm` into a different module, your integration tests should keep passing — they're black-box testing the deployed URL.

**Cover the boring stuff too.** It's tempting to just test positive/negative/neutral and call it done. But real users send empty strings, single characters, emoji, non-English text, extremely long text, and text with quotes and HTML. Each of those has bitten someone in production. Include a few of each.

**Assert on data shapes, not just data.** For an LLM app especially, exact output can vary between requests (temperature, model updates). Assert that `confidence` is in [0, 1] and is a float — not that it's exactly 0.98. Assert that `sentiment` is one of the allowed values — not that any specific input produces "positive".

**Time your tests.** Stress tests are just integration tests plus a stopwatch. Knowing "under load, /analyze goes from 400ms to 4000ms" is production-critical information. A `--stress` flag on your integration script is a mini load test.

**Don't test what upstream tests.** Your tests shouldn't verify that FastAPI returns 422 for a malformed body — that's FastAPI's test suite's job. Test *your* logic — that your endpoints call the right helpers, return the expected shapes, handle the edge cases you designed for.

### Why we don't do this in CI (yet)

In a real production shop with an internal network + budget for extra infrastructure, the integration test would run automatically as a `deploy-staging` → `integration-tests` → `deploy-prod` chain in GitHub Actions. Merging to `main` would be blocked until integration tests pass.

Our setup can't do that yet because GitHub-hosted Actions runners are on the public internet and can't reach VPN-only staging URLs. That would need a self-hosted GitHub Actions runner running inside the CS VPN — which is planned but not yet built.

Until then, running `integration-test.sh` before opening the PR from staging → main is the manual equivalent. When the class scales up and a self-hosted runner exists, the exact same script will just move from "you run it manually" to "Actions runs it automatically". Same tests, same shape, more automation.

### Where each tier catches what

| Bug type | Tier 1 (`test-local`) | Tier 2 (`/health`) | Tier 3 (`integration-test`) |
|---|---|---|---|
| Syntax error, import bug | ✅ | (would never deploy) | (would never deploy) |
| Broken endpoint URL | ✅ | ✅ | ✅ |
| App can't reach LLM in staging | ❌ (local works) | ✅ | ✅ |
| GPU allocation missing | ❌ (fallback to CPU on Mac) | ✅ | ✅ |
| Response shape wrong under specific input | ❌ (happy path only) | ❌ (single scripted check) | ✅ |
| Model gives poor accuracy on real user data | ❌ | ❌ | ✅ |
| Regression from a code change altering behavior | ❌ | ❌ | ✅ |

Each tier is a legit safety net at a different depth. Skipping any of them means bugs that could've been caught earlier get caught later — often by users.

## Section 7: Making your deploys fast (when they get slow)

When you first ship the app from Section 1, your deploy cycle will feel great — small image, small dependencies, ~30 seconds from push to running container. But the moment you add a real ML dependency (`torch`, `transformers`, a HuggingFace model, `spacy` with a language pack, etc.), each deploy suddenly takes **5-6 minutes**. That's slow enough to break your development flow.

This section explains why that happens and the pattern professional teams use to fix it. It's genuinely important — if your project uses local ML models, you'll hit this problem, and knowing the fix is a legitimate industry skill.

### Why deploys get slow

Look at what happens when Coolify builds your image on every push:

1. Pull the Python base image (`python:3.12-slim` — small, ~50 MB, fast)
2. `pip install -r requirements.txt` — downloads and installs everything on your dependency list. If that includes `torch`, that's a 750 MB download and ~2-3 minutes of installation.
3. `RUN python -c "AutoModel.from_pretrained('...')"` — if you pre-download an ML model, another ~500 MB and ~1 minute.
4. `COPY main.py .` — your 8 KB of actual code. ~0.01 seconds.
5. Container starts, model loads into VRAM. ~30-60 seconds.

Steps 2 and 3 dominate. On every single push. Even when you only changed `main.py`. Even when you added a print statement. That's the problem.

### The core concept — docker layer caching

Every line in a `Dockerfile` produces a **layer**. Docker caches layers by their input hash. If nothing that affects a layer has changed, Docker reuses the cached layer instead of rebuilding it. Fast.

But if any input to a layer changes, that layer AND every layer after it invalidate. Docker has to rebuild them all.

**The strategic implication:** put the stuff that changes rarely (dependencies) at the top of the Dockerfile, and the stuff that changes often (your code) at the bottom. That way `COPY main.py` invalidating doesn't force a torch reinstall.

The reference app already does this correctly — `requirements.txt` is copied and installed before `main.py` is copied. If only `main.py` changes, only the `COPY main.py` layer needs to rebuild. **In principle.**

### Why that isn't enough

The problem: **Docker's layer cache is local to the machine doing the build.** If Coolify's build container has the cache (which it does — same rigel host, persistent), all good. But if the build happens on an ephemeral runner (GitHub Actions VMs, a fresh CI worker), there's no cache. Every build starts from scratch — torch reinstalls, model re-downloads.

For classroom deploys through Coolify, this means: the first-ever deploy is slow (Coolify pulls the base image once), but subsequent code-only deploys should hit the cache and be fast.

Except… we noticed a real deploy still took 5 minutes even after Coolify had the layers cached. Why?

Because Coolify actually rebuilds from scratch on each deploy in the default configuration, discarding intermediate layers. Some CI/CD platforms do this for cleanliness; the tradeoff is speed.

### The two-Dockerfile pattern

The fix professional ML teams use: **split your Dockerfile into two files.**

```
Dockerfile.base   ← heavy stuff: Python + torch + transformers + HF model
Dockerfile        ← thin: FROM the base image + COPY main.py
```

**Base image (`Dockerfile.base`)** — contains everything that changes rarely. It gets built once and pushed to a container registry (like GitHub Container Registry — `ghcr.io`). The resulting image is ~1.8 GB.

**App image (`Dockerfile`)** — starts with `FROM ghcr.io/<you>/<your-base>:latest` and just adds `main.py`. Rebuilds on every push. Since almost nothing new happens (base is already in the registry, only one tiny `COPY` runs), it's a few seconds of work.

The magic: **when you push a code-only change, Coolify does not rebuild the base image.** It pulls the already-published base image (fast — that's a local cache hit on rigel), applies the tiny `COPY main.py` layer, and swaps in the new container. Total: seconds instead of minutes.

### Setting it up in your own repo

If your app has a heavy dependency (torch, tensorflow, a large HF model, spacy language packs, etc.), do this:

**1. Create a `Dockerfile.base`** with the heavy stuff:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# If you use a HuggingFace model, pre-download it here.
# Single-line RUN — do NOT use backslash continuations; some CI/CD tools
# inject synthetic ARG directives that break multi-line RUN.
ARG LOCAL_MODEL_ID=<your-hf-model-id>
ENV LOCAL_MODEL_ID=${LOCAL_MODEL_ID}
RUN python -c "from transformers import AutoTokenizer, AutoModelForSequenceClassification; AutoTokenizer.from_pretrained('${LOCAL_MODEL_ID}'); AutoModelForSequenceClassification.from_pretrained('${LOCAL_MODEL_ID}')"
```

**2. Change your `Dockerfile`** to start from the base:

```dockerfile
FROM ghcr.io/<your-github-username>/<your-repo>-base:latest
WORKDIR /app
COPY main.py .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**3. Add a workflow file** `.github/workflows/build-base.yml` that builds and pushes the base image only when it needs to:

```yaml
name: Build base image

on:
  push:
    branches: [main]
    paths:
      - requirements.txt
      - Dockerfile.base
      - .github/workflows/build-base.yml
  workflow_dispatch:

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4.2.2
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v5
        with:
          context: .
          file: Dockerfile.base
          push: true
          tags: ghcr.io/<your-username>/<your-repo>-base:latest
          cache-from: type=registry,ref=ghcr.io/<your-username>/<your-repo>-base:buildcache
          cache-to: type=registry,ref=ghcr.io/<your-username>/<your-repo>-base:buildcache,mode=max
```

**4. Make the pushed image public** on GitHub Container Registry (packages tab of your GitHub profile). Coolify's build container needs to pull it without auth.

**5. First push** — the base workflow runs, publishing the base image. Takes 5-8 minutes because there's no cache yet. Subsequent runs of the base workflow use the `buildcache` tag and take ~1-2 minutes.

**6. Code-only pushes** — the regular deploy pipeline runs, Coolify pulls the (now cached) base image, adds `main.py`, deploys. Total: under a minute.

### The tradeoffs — is this worth it?

**Do it if:**
- Your dependencies total more than ~500 MB
- Your dependencies change less often than your code (typical for ML apps)
- Deploy latency is affecting your development flow

**Don't bother if:**
- Your app is small — a plain FastAPI service with no ML deps is fine as a single Dockerfile
- You add pip dependencies as often as you change code (the base image would rebuild constantly, defeating the point)
- Deploy latency doesn't matter for your use case (batch jobs, once-a-week releases)

For most students building simple web APIs, a single Dockerfile is fine. **You only need this pattern once your app gets heavy.** Recognize the smell — 5+ minute deploys where 99% of the time is spent reinstalling dependencies that didn't change — and reach for this pattern when you see it.

### Alternative patterns you'll see in industry

For completeness, this isn't the only way. Real production ML systems also use:

**Model-as-a-service.** Don't ship the model in your app at all — call a shared service. This is what the classroom does for `classroom-chat`: Qwen3-Coder-Next runs as a long-lived vLLM service on castor+pollux, and your app is a tiny client that hits `http://ml-capstone.cs.byu.edu:4000/v1`. Your app image goes from 3 GB to 100 MB, no GPU allocation needed. Trade-off: you don't own the model server, and if it goes down, you go down.

**Persistent volume mount.** Mount the model weights from a shared filesystem at runtime instead of baking them into the image. Image stays tiny; container startup does the loading. Trade-off: needs a persistent-volume system (Kubernetes PV, NFS, etc.) — Coolify doesn't do this out of the box.

**Just accept slow deploys, invest in local testing.** If deploys are infrequent (like a weekly release), the 5-minute cycle doesn't matter much. Put your effort into a fast local dev loop (`test-local.sh` in this pattern) so you rarely need to deploy.

### The full worked example

The classroom's reference app — `github.com/byu-ml-capstone/sentiment-test-app` — implements this pattern end-to-end. Its README's "How this app is packaged (and why)" section has:

- Exact file contents for `Dockerfile.base`, `Dockerfile`, and the base-build workflow
- Actual performance numbers (before/after)
- A table of where docker caches live in different parts of the CI/CD pipeline
- More on why the pattern works and when it doesn't

Read that once, especially if your project imports torch or transformers. It'll save you real time.

## Section 8: The day-to-day update–test–PR–deploy workflow

The full workflow, from a feature idea to code in production:

### Step 1 — Feature branch off `staging`

```bash
git checkout staging
git pull origin staging
git checkout -b add-emoji-endpoint
```

### Step 2 — Write code and unit tests locally

```bash
# ... edit hello/main.py, add hello/tests/test_emoji.py, verify with pytest and docker locally
pytest tests/ --ignore=tests/integration -v      # unit tests
docker build -t sentiment-app .                  # verify Dockerfile
```

### Step 3 — Push feature branch, open PR into `staging`

```bash
git add .
git commit -m "add /emoji endpoint"
git push origin add-emoji-endpoint
```

On GitHub: **Compare & pull request** → set base to `staging`. When the PR opens, the `test` job runs. Fix any failures.

### Step 4 — Merge PR → auto-deploy to staging

Merging your PR into `staging` pushes to `staging`, triggering:

- `test` (again, on merge commit)
- `deploy-staging` (Coolify deploys to your staging URL, gated by the deep `/health` check — see Section 6, Tier 2)

Coolify's health check is the Tier 2 gate — a bad container never becomes the live staging container. But that's just a scripted check; it doesn't cover the full range of inputs your users will send.

### Step 5 — Run integration tests against staging (Section 6, Tier 3)

Before promoting to prod, run the integration tests against the live staging URL:

```bash
./integration-test.sh --staging
```

That's ~15 checks covering happy paths (positive/negative/neutral samples), edge cases (empty input, unicode, long text, special chars), and response-shape contracts. Optional `--stress` adds concurrency/throughput checks.

If any fail — investigate, fix, push to `staging` again. Do NOT open the promotion PR until the integration tests are green.

If all pass, you know staging holds up against the diverse real inputs users will send. **Safe to promote.**

### Step 6 — Open a "promotion" PR from `staging` into `main`

```bash
git checkout main
git pull origin main
git merge staging                    # or use a GitHub PR from staging → main
git push origin main
```

Or (recommended, so someone reviews before prod deploy):

- On GitHub: **New Pull Request** → base `main` ← compare `staging` → open PR
- PR page runs `test` again
- Reviewer sanity-checks the diff and the live staging URL
- **Merge** → pushes to `main` → `deploy-prod` fires → prod URL updates

### Step 7 — Rollback

If prod breaks after a merge:

```bash
git revert <bad-commit-sha>          # creates an inverse commit
git push origin main                 # triggers deploy-prod with the revert
```

Prod redeploys to the pre-bad state within a minute. Real teams do this — reverting is a normal, healthy CI/CD move, not an admission of failure.

### Never push directly to `main` or `staging`

The PR flow forces tests to run and gives someone (you or a reviewer) a chance to check the diff. Direct pushes bypass the safety net. GitHub can enforce this via **branch protection rules** (Settings → Branches → Add branch protection rule) — worth setting up on `main` at minimum.

---

# Using the classroom LLM from inside your deployed app

If your app calls the classroom LLM (like the sentiment app above), point at the same endpoint students' editors use:

- **URL:** `http://ml-capstone.cs.byu.edu:4000/v1`
- **API key:** `sk-noauth`
- **Model:** `classroom-chat` (or `classroom-autocomplete` for FIM)

Set these via **env vars**, never hardcode:

- **In prod (Coolify):** ask your instructor to add `LITELLM_URL`, `LITELLM_API_KEY`, `MODEL` to your Application's Environment Variables in Coolify.
- **In local dev:** use the `.env` file pattern from Section 1g.
- **In your code:** read via `os.environ["LITELLM_URL"]` (Python) or `process.env.LITELLM_URL` (Node), etc.

Full working example: `github.com/byu-ml-capstone/sentiment-test-app`.

---

# Using a GPU in your app

If your app needs a GPU (small model inference, media processing, ML training), add a `docker-compose.yml` at the repo root:

```yaml
services:
  app:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```

GPUs are shared, first-come-first-served — one container per GPU. If all are taken, your deploy fails to start; ask on the class channel who's using them and coordinate.

Only ask for a GPU if you actually need one — most apps (web APIs, LLM proxies, dashboards) don't.

---

# Persistent storage (databases, uploaded files, anything stateful)

**The problem:** by default, everything a container writes to its own filesystem is lost the next time the container is recreated — and Coolify recreates the container on every deploy. If your app writes to a local SQLite file, or uploads land in `/app/uploads`, they're gone on the next push.

**The fix:** Docker **named volumes**. Docker keeps them in its own managed storage on the host (`/var/lib/docker/volumes` on Linux). Mount a volume into the container at whatever path holds the data, and the data outlives the container.

The template already demonstrates this with the `db` sidecar (Postgres). Same pattern works for any stateful service.

## What the template ships

`docker-compose.yaml` at the repo root has:

```yaml
services:
  hello:
    depends_on:
      db:
        condition: service_healthy      # hello only starts after db is up
    environment:
      - DATABASE_URL=postgresql://appuser:apppass@db:5432/appdb

  db:
    image: postgres:16-alpine           # stock image — the db container is dumb storage
    environment:
      - POSTGRES_USER=appuser
      - POSTGRES_PASSWORD=apppass
      - POSTGRES_DB=appdb
    volumes:
      - db-data:/var/lib/postgresql/data      # ← THE PERSISTENT BIT
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U appuser -d appdb"]
      interval: 5s
      retries: 10

volumes:
  db-data:                             # named volume declaration
```

One mount on `db`: **`db-data:/var/lib/postgresql/data`** — the Postgres data directory lives on a named volume Docker manages. Survives `docker compose down`, redeploys, image rebuilds, host reboots. **Only** removed by `docker compose down -v`, `docker volume rm`, or deleting the Application in Coolify with the "delete volumes" box checked.

## Who owns the schema

The db container ships empty (just the `POSTGRES_USER`/`POSTGRES_DB` from the env vars — no app tables). The `hello` app owns its schema and creates it at startup via a FastAPI lifespan hook. All the actual SQL lives in a small **DAO** (`hello/notes_dao.py`) — a `NotesDAO` class that encapsulates every database interaction:

```python
# hello/notes_dao.py — abbreviated
CREATE_NOTES_SQL = """
CREATE TABLE IF NOT EXISTS notes (
    id         SERIAL       PRIMARY KEY,
    body       TEXT         NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
)
"""

class NotesDAO:
    def __init__(self, database_url: str):
        self.database_url = database_url

    def ensure_schema(self) -> None: ...    # runs CREATE TABLE IF NOT EXISTS
    def list_all(self)     -> list[dict]: ...
    def insert(self, body) -> dict: ...
    def reset(self)        -> None: ...     # DROP + CREATE for /admin/reset
```

And `main.py` becomes thin — routes handle HTTP framing and delegate to the DAO:

```python
# hello/main.py — abbreviated
from notes_dao import NotesDAO
notes_dao = NotesDAO(DATABASE_URL)

@asynccontextmanager
async def lifespan(_app):
    notes_dao.ensure_schema()   # idempotent — safe on every startup
    yield

app = FastAPI(..., lifespan=lifespan)

@app.get("/notes")
def list_notes():
    return notes_dao.list_all()
```

**Why the DAO?** Three things get easier as you scale:

- **Routes stay thin.** `main.py` reads like an HTTP contract, not a SQL script. Compare grepping `main.py` for "what HTTP endpoints exist" against `notes_dao.py` for "what SQL runs" — clear split, easy to navigate.
- **Testing is cleaner.** Route tests patch DAO methods (`patch.object(main.notes_dao, "list_all", return_value=[...])`) instead of mocking psycopg's cursor/context-manager stack. See `hello/tests/test_api.py` — the `/notes` tests are ~3 lines each vs. ~10 lines when mocking psycopg directly.
- **Swappable storage.** Want SQLite for a quick local test? Point NotesDAO at a different URL. Outgrow raw SQL and want SQLAlchemy? Replace `notes_dao.py`; `main.py` is unaffected because it only sees Python dicts.

Why this pattern (vs. an `init.sql` inside the db container)?

- **DB is a generic storage service.** Postgres doesn't care what tables you want. Swap it for MySQL, Cockroach, or a managed cloud DB and the db side changes ~5 lines; the app side stays the same because the schema definition lives with the code that uses it.
- **Schema is code, and code lives with the app.** Same PR that adds a new endpoint adds the column it needs. Same test suite. Same CI. No coordinating across two repositories or two subdirectories.
- **Self-healing.** `CREATE TABLE IF NOT EXISTS` runs on every app startup. If Postgres's data directory is fresh (first deploy ever), it creates the tables. If it's an existing volume with no schema (e.g. after a failed first deploy that half-initialized the data dir), it recovers automatically. If the tables already exist, it's a no-op.
- **Follows the modern web-app convention.** Django, Rails, FastAPI+Alembic, Prisma, sqlx — they all put migrations in the app codebase and run them at startup or via a dedicated migration command. This template does the smallest possible version of that (`CREATE TABLE IF NOT EXISTS` in a lifespan hook) for teaching purposes.

**Limitation:** the lifespan hook only handles **additive** schema changes (add a table, add a column with `IF NOT EXISTS`). For destructive changes (rename column, drop column, change type, backfill data) you need a real migration tool that tracks what's been applied — Alembic is the standard choice for FastAPI apps. For this class project, additive-only is almost always enough; adopt Alembic when you outgrow it.

## Prove it locally

The best way to internalize this: watch data survive a full `down`/`up` cycle on your laptop.

```bash
# 1. Start everything and insert two rows
./test-local.sh          # or: docker compose up -d --build

curl -X POST http://127.0.0.1:8000/notes \
  -H 'Content-Type: application/json' -d '{"body":"first"}'
curl -X POST http://127.0.0.1:8000/notes \
  -H 'Content-Type: application/json' -d '{"body":"second"}'

curl http://127.0.0.1:8000/notes
# [{"id":1,"body":"first",...}, {"id":2,"body":"second",...}]

# 2. Take everything down. Containers gone. Volume stays.
docker compose down
docker volume ls | grep db-data
# hello-world-app_db-data          <-- still there

# 3. Bring it back up
docker compose up -d
sleep 5

# 4. Rows are still there
curl http://127.0.0.1:8000/notes
# [{"id":1,"body":"first",...}, {"id":2,"body":"second",...}]

# 5. Nuclear option — the -v flag deletes volumes
docker compose down -v
docker compose up -d
sleep 5

curl http://127.0.0.1:8000/notes
# []       <-- data gone, fresh volume, app recreated the table on startup, empty
```

That five-step cycle is the mental model. Deploys are equivalent to `down`/`up` at the container level, so **your data survives deploys** the same way it survived `docker compose down` here.

## How Coolify handles this

Good news: **nothing to configure**. If your `docker-compose.yaml` declares a named volume, Coolify creates it on first deploy and reuses it forever after.

- **Volumes tab in Coolify UI.** Open your Application → **Storages** (or **Persistent Storage** depending on version) tab. You'll see the named volumes Coolify allocated, with their host paths. Useful for confirming the volume exists and inspecting size; you rarely edit anything here for a Compose build pack (declare in the compose file instead).
- **Staging and prod are isolated.** Your staging Application and your prod Application are two different Coolify Applications → they each get their own `db-data` volume on rigel. They do NOT share data. **This is the correct default** — you never want staging test data mixed with prod user data.
- **Deploys don't touch the volume.** On every push-to-deploy Coolify runs `docker compose down && docker compose up -d --build`. The container is recreated with the new image; the volume mount attaches to the same on-disk data. Zero data loss.
- **Removing an Application.** If you delete an Application in Coolify's UI, you'll be asked whether to also delete its volumes. Uncheck that box and the data survives — you can point a new Application at the same volume later.

## Cleaning up when things go wrong

Persistence protects your data — which is a problem when the data is what's wrong. Two common scenarios and the fix for each:

### Scenario 1: schema needs to change (non-additive) or data got corrupted

Wipe just the app tables, keep the Postgres volume. The template ships an env-gated admin endpoint for this:

```bash
# Local dev (docker-compose.override.yml pre-enables it):
curl -X POST http://127.0.0.1:8000/admin/reset
# {"ok":true,"message":"notes table dropped and recreated (empty)"}

# In Coolify (staging or prod):
# 1. Application → Environment Variables → add ALLOW_ADMIN_RESET=true → Save
# 2. Redeploy so the container picks up the new env
# 3. curl -X POST http://<your-domain>/admin/reset
# 4. Remove the env var so nobody can accidentally hit it again → Redeploy
```

Under the hood this calls `notes_dao.reset()`, which runs `DROP TABLE IF EXISTS notes` then `CREATE TABLE IF NOT EXISTS notes (...)`. All rows gone, table shape refreshed to whatever `notes_dao.py` currently says. Great for iterating on schema changes without touching the volume.

**When to use:** you changed the columns and just want the table to match the new definition. Or you filled the table with test junk and want a clean slate.

**Why env-gated:** a public `/admin/reset` that anyone could hit would be an ~1-second data-loss button. The `ALLOW_ADMIN_RESET` env var makes destructive endpoints opt-in and easy to disable again.

### Scenario 2: the volume itself is what's broken (full disk, corrupted files, or you want to start truly fresh)

Nuke the volume. Coolify's UI hides volume-delete for auto-declared compose volumes, so you have three routes, easiest last:

- **Local dev:** `docker compose down -v` then `docker compose up -d --build`. The `-v` flag removes named volumes; next `up` recreates them empty and the app repopulates the schema via the lifespan hook.
- **SSH to rigel** (instructor-only for this cluster):
  ```bash
  # Volume name is <coolify-uuid>_db-data — check the deploy log for the exact name.
  docker volume rm <coolify-uuid>_db-data
  ```
  Then trigger a redeploy in Coolify.
- **Delete and recreate the Coolify Application** with the "delete volumes" checkbox ticked. Nuclear — you'll re-add the domain, secrets, and env vars. Only sensible if the Application state is also wrong.

For everyday schema iteration, prefer Scenario 1's `/admin/reset` — no SSH, no Coolify Application juggling.

## Evolving the schema (migrations + maintenance)

Every real app changes its schema over time: add a column, add a table, backfill data, drop a stale index. "SSH to the DB machine and run `psql`" is the classic maintenance workflow — that translates here to **`docker exec` into the db container and run `psql` from there**, since the DB is a container on rigel that isn't directly reachable from your laptop.

Three tools cover the full range of what you'll need. Pick based on the change, not the tool you like:

| Change type | Tool | Where you edit / run |
|---|---|---|
| Additive (new table, new column with default) | `notes_dao.ensure_schema()` | Edit `hello/notes_dao.py`, push, redeploy — runs automatically |
| One-off / destructive (rename, drop, backfill, index tuning) | `psql` in the db container | Interactive `docker exec` from Coolify Terminal, SSH to rigel, or local `docker compose exec` |
| Team-scale (multiple contributors, up/down migrations, version tracking) | Alembic (or similar) | Migration files in `hello/migrations/`, versioned in git |

### Everyday additive changes (edit `ensure_schema` and push)

Since the schema lives in code (`hello/notes_dao.py`), most changes are just edits to the DAO. Extend `CREATE_NOTES_SQL` for new tables; add `ALTER TABLE ... IF NOT EXISTS` statements for new columns. The lifespan hook runs `ensure_schema()` on every startup, so any additive change picks up on the next deploy.

Example: adding a `priority` column to `notes`:

```python
# hello/notes_dao.py — extended
CREATE_NOTES_SQL = """
CREATE TABLE IF NOT EXISTS notes (
    id         SERIAL       PRIMARY KEY,
    body       TEXT         NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
)
"""

ADD_PRIORITY_COLUMN_SQL = """
ALTER TABLE notes ADD COLUMN IF NOT EXISTS priority INT NOT NULL DEFAULT 0
"""

class NotesDAO:
    def ensure_schema(self) -> None:
        with psycopg.connect(self.database_url) as conn, conn.cursor() as cur:
            cur.execute(CREATE_NOTES_SQL)
            cur.execute(ADD_PRIORITY_COLUMN_SQL)   # idempotent — no-op after first run
```

Push, redeploy, done. Existing rows get `priority = 0`; the app can start reading/writing the column immediately. Works for:

- New tables (`CREATE TABLE IF NOT EXISTS`)
- New columns (`ADD COLUMN IF NOT EXISTS` — Postgres 9.6+)
- New indexes (`CREATE INDEX IF NOT EXISTS`)
- New constraints, as long as they don't fail on existing data

Doesn't work for renames, drops, type changes, or anything that transforms existing data — for that, drop to the next tool.

### One-off maintenance via `psql`

For anything the additive pattern can't handle — renaming a column, dropping a column, backfilling data, rebuilding an index — open a `psql` shell against the running db container and run SQL by hand.

**Locally:**

```bash
docker compose exec db psql -U appuser -d appdb
# psql (16.x)
# appdb=# \dt
#              List of relations
#  Schema | Name  | Type  |  Owner
# --------+-------+-------+---------
#  public | notes | table | appuser
# appdb=# ALTER TABLE notes RENAME COLUMN body TO content;
# ALTER TABLE
# appdb=# \q
```

**In Coolify (instructor / anyone with rigel SSH):**

```bash
ssh rigel
# List the db containers:
docker ps --filter name=db- --format 'table {{.Names}}\t{{.Image}}'
# Then exec in:
docker exec -it db-<coolify-uuid>-<timestamp> psql -U appuser -d appdb
```

**In Coolify UI (if your Coolify version has the Terminal tab):**

Open the db resource → **Terminal** tab → run `psql -U appuser -d appdb`. Same shell, no SSH needed.

**Common maintenance recipes** — run all of these from inside `psql`:

```sql
-- Rename a column (destructive, requires app code update in the same deploy)
ALTER TABLE notes RENAME COLUMN body TO content;

-- Change a column type (works if the cast is unambiguous)
ALTER TABLE notes ALTER COLUMN priority TYPE BIGINT;

-- Backfill a new column based on old data
UPDATE notes SET priority = 1 WHERE created_at > NOW() - INTERVAL '7 days';

-- Drop a stale index
DROP INDEX IF EXISTS notes_body_idx;

-- One-off cleanup — delete test junk
DELETE FROM notes WHERE body LIKE 'test-%';

-- Full backup to a local file (run on the host, not inside psql)
docker compose exec db pg_dump -U appuser appdb > backup-2026-08-20.sql

-- Restore from a local file
cat backup-2026-08-20.sql | docker compose exec -T db psql -U appuser appdb
```

**When to sync with a code change:** most maintenance is "the SQL first, then the code that expects the new shape" — but this splits the change over two moments where the app is in a partial state. For destructive changes prefer this sequence:

1. Add the new column additively via `ensure_schema()`, deploy.
2. Backfill via `psql` if needed.
3. Update the app code to use the new column, deploy.
4. Later (a week? a release?), drop the old column via `psql`.

The pattern is "expand → migrate data → contract" and it's how zero-downtime schema changes work at real companies. For a class project you can usually skip the intermediate deploys and just do the reset dance (`POST /admin/reset` + push new code) since data loss isn't a real cost.

### When to promote to Alembic

Adopt a real migration tool when you hit any of these:

- More than one person is changing the schema; you need to know "have I applied Alice's migration yet?"
- You want reversible migrations (down as well as up).
- You need to track migration history in the DB for auditing.
- The `ensure_schema()` function is more than ~50 lines of DDL and you can't easily reason about what state the schema is in.

For FastAPI + psycopg the standard tool is **Alembic** (part of the SQLAlchemy ecosystem — works fine without SQLAlchemy models, just SQL). Migrations live in `hello/migrations/versions/*.py`. Run `alembic upgrade head` at deploy time (in the lifespan hook, or as a separate compose command) to apply pending migrations.

Class projects almost never need this. Real production apps almost always do. When you're in doubt, the `ensure_schema` pattern is fine — you can always add Alembic later without throwing away your existing work.

## Moving data between environments

Since staging and prod don't share volumes, there's no automatic promotion of data from staging to prod (or backfill from prod to staging). If you actually need this — e.g., copy a snapshot of prod data into staging so you can test against real-shaped data — use `pg_dump` and `psql`:

```bash
# On rigel (or wherever prod runs), dump the prod db:
docker compose exec db pg_dump -U appuser appdb > prod-snapshot.sql

# Copy the dump wherever you'll restore it. On the staging deploy host:
cat prod-snapshot.sql | docker compose exec -T db psql -U appuser appdb
```

Do NOT try to share a volume between two Applications by hand — you'd have both environments writing to the same rows and no way to reason about state.

## Backups (or: why this matters less for class projects)

Named volumes live on rigel's disk. If rigel dies, they're gone unless someone has a backup running elsewhere. **The class cluster does not currently back up student volumes.** For your class project this is fine — worst case, wipe the volume and let the app recreate the schema on startup. For real production data at a real company, you'd run a nightly `pg_dump` job that ships to S3 / rclone / whatever.

## Common gotchas

- **Non-additive schema changes don't self-apply.** The lifespan hook only runs `CREATE TABLE IF NOT EXISTS` — safe on every startup, but a no-op if the table already exists. Renaming a column, dropping one, or changing a type won't propagate this way. When you need that, either wipe the volume (dev only) or add a real migration tool (Alembic for FastAPI). For adding new columns you can extend the lifespan hook with `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` — still idempotent, still safe.
- **Schema mismatches after code changes.** If your app queries a column that doesn't exist in the persisted volume, you'll get uncaught SQL errors → 500. Fix: extend the lifespan hook with an `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, or wipe the volume locally to force a fresh start.
- **Wrong volume-vs-bind-mount syntax.** `db-data:/path` (no leading `./` or `/`) → named volume, managed by Docker. `./local/thing:/path:ro` → bind-mount from the repo, read-only. Mixing them up gives silent failures. (The template avoids bind-mounts entirely because Coolify's extract-to-artifacts flow doesn't always propagate the source file to the container runtime.)
- **`docker compose down -v` in production.** Never run this by hand on rigel unless you actually want to lose the data. Coolify does NOT pass `-v` when it redeploys; it's a footgun for humans.
- **Coolify's `docker compose down` cleanup on redeploy.** Coolify's redeploy runs `docker compose down && docker compose up -d --build` without `-v`, so volumes always persist across deploys. Confirmed live on ml-capstone.

---

# Troubleshooting

## LLM (editor) doesn't respond

- **You're off VPN.** `curl http://ml-capstone.cs.byu.edu:4000/v1/models` should return JSON. If it fails, fix VPN before touching editor config.
- **Continue on wrong assistant.** See "If you get stuck" in Option 1.
- **Copilot fighting Continue** — see Option 1 step 2.

## Deploy doesn't happen after push

- **Tests failed** — GitHub Actions tab shows red. Look at logs, fix, re-push.
- **`COOLIFY_DEPLOY_WEBHOOK_STAGING` or `_PROD` secret missing or wrong** — Actions log will show a curl error.
- **You pushed to a feature branch, not `staging` or `main`** — deploy jobs only run on those branches. Feature branches only run `test`.
- **Deploy fires but Coolify marks it failed** — the `/health` endpoint is returning non-2xx. Check Coolify's deploy log; probably an LLM/env/dependency issue that only shows up in the deployed environment. Fix locally, push, retry.
- **Coolify deploy log says `Bind for 0.0.0.0:8000 failed: port is already allocated`** — you're on the Docker Compose build pack and your `docker-compose.yaml` has `ports: "8000:8000"`. That binds host port 8000, and the shared cluster server only lets ONE container own each host port. Replace `ports:` with `expose: - "8000"` — Coolify + Traefik route the domain to your container over the internal `coolify` Docker network based on the Port field in Coolify's Application settings, so no host port binding is needed. (The `hello-world-app` template's `docker-compose.yaml` shows the correct pattern.)

## Deploy runs but app is unreachable

- **App bound to `127.0.0.1`** — see Dockerfile gotchas. Use `--host 0.0.0.0`.
- **Wrong port** — container must `EXPOSE` and listen on the port Coolify's Application config expects (usually 8000).
- **App crashed on startup** — check Coolify logs via your instructor; likely a Python traceback in `main:app`.
- **You're not on VPN** — deployed apps are VPN-only.

## Cluster fully down

- Individual GPU crashes are handled automatically — you'll see one transient error, then requests route to the surviving GPU.
- If ALL LLM requests time out, the front-end host is down. Contact your instructor.

Emergency direct-to-vLLM (only if instructor confirms front-end is down):

- Chat: `http://castor.cs.byu.edu:8000/v1` or `http://pollux.cs.byu.edu:8000/v1`
- Autocomplete: `http://castor.cs.byu.edu:8010/v1` or `http://pollux.cs.byu.edu:8010/v1`

These bypass LiteLLM, so you must change the *model name* in your client from `classroom-chat` to the raw HF id your instructor is running (usually `Qwen/Qwen3-Coder-Next-FP8`).

---

# Quick reference

| What | Value |
|---|---|
| Classroom LLM endpoint | `http://ml-capstone.cs.byu.edu:4000/v1` |
| API key placeholder | `sk-noauth` |
| Chat model | `classroom-chat` |
| Autocomplete model | `classroom-autocomplete` (Continue only) |
| VPN gateway | `cs-vpn.byu.edu` (GlobalProtect client) |
| Coolify admin UI | `https://ml-capstone-admin.cs.byu.edu` (VPN) |
| GitHub org | `github.com/byu-ml-capstone` |
| Your staging URL | `http://<your-repo>-staging.ml-capstone.cs.byu.edu` |
| Your prod URL | `http://<your-repo>.ml-capstone.cs.byu.edu` |
| Repo naming convention | `<your-repo>` under `byu-ml-capstone/` |
| Container port your app must listen on | `8000` (matches Coolify's Port setting) |
| Container bind address | `0.0.0.0` (not `127.0.0.1` — see Section 1e) |
| GitHub Actions secrets you'll set | `COOLIFY_DEPLOY_WEBHOOK_STAGING`, `COOLIFY_DEPLOY_WEBHOOK_PROD`, `COOLIFY_API_TOKEN` |
| Template repo | `github.com/byu-ml-capstone/hello-world-app` (Use this template) |
| Reference app | `github.com/byu-ml-capstone/sentiment-test-app` |
