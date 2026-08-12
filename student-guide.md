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
  - [Setup: Sign in and create your Coolify Applications](#setup-sign-in-and-create-your-coolify-applications) — the 11-step onboarding lab
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
- [Troubleshooting](#troubleshooting)
- [Quick reference](#quick-reference)

## Before you start

**Install GlobalProtect and connect to the CS VPN** — the cluster is on the CS network. Only one URL (the GitHub webhook path) is reachable from the public internet; everything else, including the LLM endpoint and your deployed apps, requires VPN.

- VPN gateway: `cs-vpn.byu.edu`
- Client: GlobalProtect (BYU IT has installers and instructions at vpn.byu.edu) 

Also make sure you have:

- A **GitHub account** — the email you use for GitHub must match the one your instructor has on the class roster. That's how Coolify's login and the org invite find you.
- **Docker installed locally** (for testing your app before pushing)
- **VS Code** or another editor of your choice

Your instructor has already:

- Provisioned you a **Coolify Team** on the classroom cluster (you'll see it after signing in)
- Sent you an **invitation to the `byu-ml-capstone` GitHub organization** — accept it before Step 4 of the Setup section below
- Set up the shared **`byu-ml-capstone-coolify` GitHub App** and **`ml-capstone` deploy server** — nothing for you to install
- Told you your **team slug** — a short name like `alice-sandbox` or `group-3` you'll use for both your GitHub repo name and your deploy domain (`<team-slug>.ml-capstone.cs.byu.edu`)

All `*.ml-capstone.cs.byu.edu` subdomains resolve internally to the classroom cluster automatically — no `/etc/hosts` tweaking needed as long as you're on the CS VPN.

If DNS resolution doesn't work when you're on VPN, verify with `nslookup <your-team-slug>.ml-capstone.cs.byu.edu` — it should return an internal `10.x.x.x` address. If it returns NXDOMAIN, your VPN's DNS resolver may be misconfigured; contact your instructor.

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
    │    → Group1-staging.ml-capstone.cs.byu.edu│
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
    │    → Group1.ml-capstone.cs.byu.edu        │
    └──────────────────────────────────────────┘
```

**What your instructor sets up (once per group at term start):**

- Provisions your Coolify Team + invites you by email (you sign in with your GitHub account — same email)
- Attaches the shared `ml-capstone` deployment server to your team
- Ensures the `byu-ml-capstone-coolify` GitHub App is available for you to install on your repo
- Wildcard DNS `*.ml-capstone.cs.byu.edu` — anything under that name resolves to the cluster

**What you (or your group) does:**

- Create a shared GitHub repo (your group owner's account or a new one)
- Sign into Coolify and set up your Applications — see **Setup: Sign in and create your Coolify Applications** below (one-time, ~15 min)
- Write your app + Dockerfile + unit tests
- Make your `/health` endpoint thorough enough to double as an automated smoke test (Section 4)
- Add a GitHub Actions workflow with the three jobs above
- Follow the branch flow: feature branch → PR to `staging` → PR to `main`

> **Roadmap note.** Automated integration tests running from GitHub Actions against the live staging URL (Vercel-style Preview Deploys with full pytest) require a self-hosted runner inside the CS VPN. That's on the roadmap for once the class grows. For now, Coolify's health check runs as the deploy gate (Section 6, Tier 2), and you run `./integration-test.sh --staging` by hand before promoting to prod (Section 6, Tier 3).

## Why staging + prod?

Real teams never merge straight into production. Staging exists to:

- **Catch bugs that only appear against real infrastructure** — networking, env vars, actual database, real dependencies
- **Let integration tests hit a live URL** — unit tests can't verify "did my LLM prompt actually work end-to-end"
- **Give reviewers something clickable** — before merging to prod, someone visits the staging URL and sanity-checks
- **Provide a rollback safety net** — if prod breaks after a merge, you can roll back knowing staging worked

This mirrors what you'll do at every serious tech company.

## Setup: Sign in and create your Coolify Applications

**Do this once, before writing any code.** ~15 minutes.

You'll:

1. Sign into Coolify with your GitHub account
2. Find your team and verify the `ml-capstone` server is attached
3. Create a Project containing production + staging Environments
4. Accept the `byu-ml-capstone` org invite + create your class repo from the `hello-world-app` template inside the org
5. Create one Application per Environment (both pointing at your class repo, different branches)
6. Turn OFF Coolify's Auto Deploy so GitHub Actions drives deploys after tests pass
7. Copy the Deploy Webhook URLs + create an API token, paste into GitHub Actions secrets
8. Push a commit to verify the pipeline works end-to-end

### 1. Sign in

Get on the BYU VPN, then open **https://ml-capstone-admin.cs.byu.edu** and click **"Sign in with GitHub"**.

**No invite email.** Your instructor has added your email to the class roster ahead of time. When you sign in with GitHub, Coolify sees that your GitHub account's primary email matches the roster row and links you to your pre-provisioned team automatically. If you see "Registration is disabled. Please contact the administrator" after authorizing GitHub, the email on your GitHub account doesn't match the roster — tell your instructor which email to use.

### 2. Find your team + verify the server

In the sidebar (or top bar depending on version), click the team switcher. You should see your team (something like `Group 3` or `Alice Sandbox`) — pick it.

**Why servers matter.** Every Application you create in Coolify has to be *deployed somewhere*. In cloud-PaaS terms, a "server" is a compute target — the physical or virtual machine that runs your containers. Your team already has one attached, called **`ml-capstone`**. Behind the scenes it's a shared physical box (`rigel.cs.byu.edu`, 4× A6000 GPUs) that hosts every team's containers — but the abstract name `ml-capstone` lets your instructor move workloads to different hardware later without changing anything you see.

Left sidebar → **Servers**. You should see one server called **`ml-capstone`** with a green "reachable" indicator. That's all you need to check — you don't need to click into the server; the details page is admin-oriented. If the server is missing, tell the instructor before continuing.

### 3. Create a Project + Environments

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

### 4. Accept the org invite + create your class repo under `byu-ml-capstone`

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
- **Repository name:** follow the class convention **`<team-slug>-<app>`** where `<team-slug>` matches your Coolify team's URL slug and `<app>` describes the app. Examples:
  - Individual sandbox phase: `alice-sandbox-hello`, `alice-sandbox-sentiment`
  - Group phase: `group-1-sentiment`, `group-3-recommender`
  - The alignment between repo name → team slug → deploy domain (`alice-sandbox.ml-capstone.cs.byu.edu`) keeps the mental model consistent as your project grows.
- **Public** or **Private** — either works; Private is fine and matches production practice
- ✅ **CHECK the box "Include all branches"**. The template ships with `main` AND `staging` branches; by default GitHub only copies `main`. Without this checkbox you'll need to create `staging` yourself later.
- Click **Create repository from template**

You now have a fresh repo at `github.com/byu-ml-capstone/<team-slug>-<app>` populated with a minimal FastAPI (`/`, `/health`, `/languages`) and the 3-job CI/CD workflow. The `byu-ml-capstone-coolify` App already has access to it — no install step needed.

**Finding your repo later:** org repos do NOT appear on your personal GitHub profile by default. To find yours:
- **Bookmark it** — the URL is stable: `github.com/byu-ml-capstone/<your-repo>`
- **Org page:** https://github.com/byu-ml-capstone lists every repo you have access to
- **Sidebar chip:** when you're signed in, GitHub shows the `byu-ml-capstone` avatar in the left sidebar of your dashboard — click it to jump to the org
- **Pin it to your profile:** on your repo's page, hover the ⭐ area → the "..." menu offers "Pin repository" — pinned repos DO show on your public profile

### 5. Create your production Application

Inside your project → click into the **production** Environment → **+ Add Resource**.

You'll see several tiles. Click **Private Repository (with GitHub App)** — **NOT** the similarly-named "Private Repository (with Deploy Key)" tile. Those look almost identical but are completely different auth flows:

- **Private Repository (with GitHub App)** ← this one — uses the `byu-ml-capstone-coolify` App the instructor set up. Correct choice.
- **Private Repository (with Deploy Key)** ← *not* this — uses an SSH deploy key you'd have to paste into your repo yourself. Different auth path; won't pair with the App and will silently fail deploys.

Coolify's Application-create flow now walks you through four screens:

**Screen 1 — Select a destination.** Coolify wants to know which Docker network to run your container on. Pick **`coolify`** (should be the only option). This is the Docker network on the `ml-capstone` server your team owns.

**Screen 2 — Select a source.** Pick **`byu-ml-capstone-coolify`**. Coolify contacts GitHub and pulls the list of repos the App can see under the org.

**Screen 3 — Select repository.** Pick your class repo (e.g., `byu-ml-capstone/<team-slug>-<app>`). Click **Load Repository** to fetch its branches.

**Screen 4 — Configuration.** Fill in:

- **Branch**: `main`
- **Build Pack**: **Dockerfile** — reads the `Dockerfile` at the repo root.
- **Base Directory**: leave blank
- **Port**: `8000` — matches the template's `EXPOSE 8000`
- **Is it a static site?**: No
- Click **Continue** — lands you on the Application's General page.

On the General page:

- **Domain**: type your team's prod domain: `http://<team-slug>.ml-capstone.cs.byu.edu` (drop the auto-generated `.sslip.io` value if one appears). Your instructor gave you the slug. Example: Group 3 → `http://group-3.ml-capstone.cs.byu.edu`.
- **Do NOT click "Generate Domain"** — that button produces a `.sslip.io` URL that can trigger a Coolify UI crash. Just type your domain in the field.

> **Why HTTP not HTTPS?** The CS wildcard cert covers `*.cs.byu.edu` (one level only), so it doesn't cover the two-level `<team-slug>.ml-capstone.cs.byu.edu` your app lives at. Rather than have every student's browser scream "Not Secure," student apps serve over plain HTTP. Traffic is already encrypted at the VPN layer, so this is safe. A future upgrade to a two-level wildcard cert would make HTTPS work naturally.
- **Save** — do NOT click Deploy yet. Auto-deploy needs turning off (Step 7) before your first deploy fires.

### 6. Create your staging Application

Navigate up to the project (breadcrumb at top) → click into the **staging** Environment → **+ Add Resource → Private Repository (with GitHub App)**. Same 4-screen flow as production. On Screen 4:

- **Branch**: `staging` — the branch dropdown should include this option if you ticked "Include all branches" during Step 4's template flow. If it doesn't, you missed the checkbox; see the callout below.
- **Build Pack**: **Dockerfile** (same as production).
- **Base Directory**: leave blank
- **Port**: `8000` — Coolify does NOT copy this from your production Application; every Application defaults to port 3000. Overriding to 8000 is easy to forget and the deploy will look healthy but the domain returns "Bad Gateway".
- **Is it a static site?**: No

> **If the `staging` branch dropdown is missing:** you skipped "Include all branches" when creating your repo. Recover on your laptop:
>
> ```bash
> git clone https://github.com/byu-ml-capstone/<your-repo>.git
> cd <your-repo>
> git checkout -b staging
> git push -u origin staging
> ```
>
> Then click the **Refresh Repository List** button in Coolify's picker (upper right of the source screen) and the `staging` branch should appear.

Then on the General page:

- **Domain**: type `http://<team-slug>-staging.ml-capstone.cs.byu.edu` in the field (do NOT click "Generate Domain").
- **Save** (don't deploy yet).

### 7. Turn OFF auto-deploy + configure GPU (Advanced tab)

Both toggles live in the same place. In each Application (do this for BOTH staging and production):

**Advanced tab → Deployment section:**

- **Auto Deploy** → toggle **OFF**

Coolify's default is "deploy on every push to the tracked branch." We don't want that — GitHub Actions runs your unit tests first, and only fires the Coolify deploy webhook if tests pass. Leaving Auto Deploy ON means every push deploys immediately without test-gating.

**Advanced tab → GPU section (optional, ML apps only):**

`hello-world-app` doesn't need a GPU — leave this section alone if you're just proving the pipeline works. Enable it when you deploy an app that uses ML models (sentiment-test-app, your own PyTorch/TF workload, etc.).

When you DO need GPU:

- **Enable GPU** → toggle **ON**
- **GPU Driver** → `nvidia`
- **GPU Count** → `1` (each container gets one A6000)
- **GPU Device Ids** → your instructor may have assigned your team a specific GPU (e.g., `0`, `1`, `2`, or `3`) to spread load across the 4× A6000s on rigel. Set that here. If unset, Docker picks any available GPU.
- **GPU Options** → leave blank

**Coolify save quirk:** the per-section **Save** buttons in the Advanced tab often DON'T persist changes on their own. After flipping Auto Deploy / configuring GPU, click back to the **General** tab and hit its **Save** button — that's what actually commits your Advanced-tab changes. Verify by refreshing the Advanced tab and checking your toggles are still where you left them.

Repeat for the other Application.
  
### 8. Grab the Deploy Webhook URLs (in Coolify)

Each Coolify Application has a Deploy Webhook URL that triggers *just the container swap* (no auto-git-check). GitHub Actions will hit these.

**Still in Coolify** (`https://ml-capstone-admin.cs.byu.edu`), for each of your two Applications:

- Open the Application → left-tab bar → click **Webhooks** → find **Deploy Webhook** → copy the URL.
- Note which one is staging and which is production. You'll paste these into GitHub secrets in Step 10 as `COOLIFY_DEPLOY_WEBHOOK_STAGING` and `COOLIFY_DEPLOY_WEBHOOK_PROD`. Paste them verbatim — no rewriting needed.

### 9. Create a Coolify API token (in Coolify)

The webhook is `deploy`-scoped by itself, but the GitHub Actions job needs a Bearer token to call it.

**Still in Coolify** (not GitHub — Coolify has its own Keys & Tokens page):

- Click the **Coolify** wordmark/logo top-left to go back to the instance dashboard
- Left sidebar → **Keys & Tokens → API Tokens → + New Token**
- **Description**: `github-actions`
- **Permissions**: check `deploy` only (nothing more; least-privilege)
- **Create** → copy the token immediately (Coolify shows it exactly once — if you lose it you'll have to make a new one).

### 10. Add three secrets to your GitHub repo (in GitHub)

**Now switch back to GitHub.** Go to your class repo (e.g., `github.com/byu-ml-capstone/<your-repo>`) → **Settings** (repo settings, not org) → left sidebar **Secrets and variables → Actions → New repository secret**. Add all three:

| Secret name | Value |
|---|---|
| `COOLIFY_DEPLOY_WEBHOOK_STAGING` | Deploy Webhook URL from the staging Application (paste verbatim from Coolify) |
| `COOLIFY_DEPLOY_WEBHOOK_PROD` | Deploy Webhook URL from the production Application (paste verbatim from Coolify) |
| `COOLIFY_API_TOKEN` | The `deploy`-scoped token you just created |

Secret names match the ones used in the `sentiment-test-app` reference workflow so you can copy the workflow file as a template.

### 11. Prove the pipeline: make a real code change (and see tests catch a bug)

You've configured everything. Time to make a real code change from your laptop and watch it flow through GitHub Actions → Coolify → your live URL. This walkthrough includes an intentional test failure — that's the point, and you'll see WHY the tests-gate-deploy pattern matters.

**Prep — clone your repo locally.**

```bash
git clone https://github.com/byu-ml-capstone/<your-repo>.git
cd <your-repo>
git branch -a
```

You should see both `main` and `staging` (assuming you ticked "Include all branches" in Step 4). If `staging` is missing:

```bash
git checkout -b staging
git push -u origin staging
git checkout main
```

**Step A — Baseline: hit both live URLs to see the current state.**

```bash
curl -s http://<team-slug>-staging.ml-capstone.cs.byu.edu/health && echo
curl -s http://<team-slug>.ml-capstone.cs.byu.edu/health && echo
```

Both should return `{"ok":true,"version":"0.1.1"}`. That's the template's starting version — you're about to change it.

**Step B — Change the app's behavior on the `staging` branch.**

```bash
git checkout staging
```

Open `greetings.py` in your editor (`code greetings.py`, `vim greetings.py`, etc.). Make TWO changes:

1. **Find the version line** and bump it:
   ```python
   APP_VERSION = "0.1.1"    # change this
   APP_VERSION = "0.1.2"    # to this
   ```

2. **Find the Spanish greeting** in the `GREETINGS` dict and update it:
   ```python
   "es": "Hola, mundo",                    # change this
   "es": "¡Buenos días, mundo!",            # to this
   ```

Save the file. Verify your diff shows exactly two changes:

```bash
git diff greetings.py
```

**Step C — Commit + push. Deliberately do NOT update the tests yet.**

```bash
git add greetings.py
git commit -m "v0.1.2: update Spanish greeting"
git push
```

**Step D — Watch GitHub Actions FAIL. This is correct behavior.**

Open `https://github.com/byu-ml-capstone/<your-repo>/actions` in a browser. New workflow run appears within seconds. Watch:

- **`test` job** runs → **fails** with an AssertionError:
  ```
  test_hello_spanish
  AssertionError: assert {'hello': '¡Buenos días, mundo!'} == {'hello': 'Hola, mundo'}
  ```
- **`deploy-staging` job** never runs — because the test failed, GitHub Actions skips it. Your staging URL still returns `0.1.1`.

**This is the whole point of the tests-gate-deploy pattern.** Your test asserted "the Spanish greeting must be `Hola, mundo`" — a contract. You changed the behavior without updating the contract. In production, you'd have shipped a lie. The test caught it BEFORE it went live.

You now have two options:

- **The change was wrong** → revert the code change and push again
- **The change was intentional** → update the test to match the new expected behavior (this is what you'll do next)

**Step E — Fix the test to match the new behavior.**

Open `tests/test_api.py` in your editor. Find `test_hello_spanish`:

```python
def test_hello_spanish():
    r = client.get("/", params={"lang": "es"})
    assert r.status_code == 200
    assert r.json() == {"hello": "Hola, mundo"}       # change this
    assert r.json() == {"hello": "¡Buenos días, mundo!"}  # to this
```

Save. Verify locally:

```bash
python3 -m pytest tests/ -v
```

All 5 tests should now pass locally.

**Step F — Commit the test fix + push.**

```bash
git add tests/test_api.py
git commit -m "test: update Spanish assertion to match v0.1.2 greeting"
git push
```

**In real life** you'd usually combine Steps B and E into a single commit — the code change and its test update belong together. We split them here to demonstrate the failure mode.

**Step G — Watch GitHub Actions succeed + Coolify deploy.**

New workflow run on GitHub Actions:
- **`test` job** — green (~30s)
- **`deploy-staging` job** — green (~5s), fires the Coolify webhook

Open the Coolify staging Application → **Deployments** tab. New deployment appears within ~10s: pull → build → healthcheck → healthy. Total ~30-60s.

**Step H — Verify staging deployed. Prod should still be at 0.1.1.**

```bash
curl -s http://<team-slug>-staging.ml-capstone.cs.byu.edu/health && echo
curl -s "http://<team-slug>-staging.ml-capstone.cs.byu.edu/?lang=es" && echo
curl -s http://<team-slug>.ml-capstone.cs.byu.edu/health && echo
```

Expected:
```
{"ok":true,"version":"0.1.2"}
{"hello":"¡Buenos días, mundo!"}
{"ok":true,"version":"0.1.1"}
```

Staging has the new behavior, prod hasn't been touched yet. This is exactly how a staging environment protects prod: you get to try changes in an environment that mirrors prod without customer impact.

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
curl -s http://<team-slug>.ml-capstone.cs.byu.edu/health && echo
curl -s "http://<team-slug>.ml-capstone.cs.byu.edu/?lang=es" && echo
```

Both should now return the 0.1.2 responses. **Your entire pipeline is proven end-to-end.** Everything after this is code — you know how the mechanics work.

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

Same repo, same Applications, same domain as your hello-world deploy — you just replace the code inside your existing class repo (`byu-ml-capstone/<team-slug>-hello-world-app` or however you named it). Coolify redeploys on your next push automatically.

### 1a. Start from your existing repo (don't create a new one)

You already have a Coolify Application wired to your class repo. Reuse it — replace the code in your existing repo rather than creating a fresh one. That way the Deploy Webhook URLs, secrets, and domain all stay the same.

```bash
cd path/to/<your-repo>          # wherever you cloned it during Setup Step 11
git checkout staging
# You'll make all the changes on staging, test them, then merge to main.
```

### 1b. Replace the code with a sentiment classifier

You can delete `greetings.py`, `main.py`, and `tests/test_api.py` from the template — you'll replace them entirely with what's below. Keep `Dockerfile`, `docker-compose.yaml`, `requirements.txt`, `.github/workflows/ci.yml`, `conftest.py`. Those stay the same shape; only the code inside changes.

### 1c. Write `main.py`

A FastAPI service with two endpoints — `/health` for status, `/analyze` for text classification via the classroom LLM.

```python
"""Small sentiment-classifier via the classroom LiteLLM.

POST /analyze  { "text": "..." }
  -> { "text", "sentiment": positive|negative|neutral, "confidence", "reasoning" }
GET  /health   -> { "ok": true, "litellm": "<url>" }

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


@app.get("/health")
def health():
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

- **`os.environ.get("LITELLM_URL", "default")`** — reads the LLM URL from an env var. Never hardcode it. Different envs (local, prod) supply different values.
- **`app.run(host="0.0.0.0")`** happens inside the container via uvicorn (see Dockerfile) — binding to loopback would make the container unreachable from Coolify's proxy.

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

Before adding tests or CI, make sure the app actually runs on your machine.

```bash
# Build the image
docker build -t sentiment-app .

# Run it, passing the .env file. --rm cleans up when you exit.
docker run --rm -p 8000:8000 --env-file .env sentiment-app
```

In another terminal:

```bash
curl http://127.0.0.1:8000/health
# {"ok":true,"litellm":"http://ml-capstone.cs.byu.edu:4000/v1","model":"classroom-chat"}

curl -X POST http://127.0.0.1:8000/analyze \
  -H 'Content-Type: application/json' \
  -d '{"text":"I loved the movie, it was fantastic!"}'
# {"text":"...","sentiment":"positive","confidence":0.98,"reasoning":"..."}
```

You must be on VPN for the container to reach the LLM.

## Section 3: Add tests

Create `tests/test_health.py`:

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

Add pytest to `requirements.txt`:

```
pytest==8.3.4
```

Run locally:

```bash
pip install -r requirements.txt
pytest -v
```

Two tests pass. Note that we don't hit the real LLM in unit tests — that would fail in CI where there's no VPN. Real integration tests belong in a separate suite that only runs against a deployed instance.

## Section 4: Make `/health` do the integration test's job

Unit tests (Section 3) verify functions in isolation. Real integration tests — hitting the live deployed URL with real requests — are what catch bugs that only show up against real infrastructure (networking, env vars, actual LLM). Those normally run in CI against staging.

**In the full setup we're aiming for**, a self-hosted GitHub Actions runner inside the CS VPN runs pytest against `http://<your-group>-staging.ml-capstone.cs.byu.edu` on every staging deploy. That runner doesn't exist yet — it's on the roadmap.

**Right now**, Coolify's built-in health check fills the role. Coolify polls your `/health` endpoint after every deploy. If it doesn't return 2xx within N attempts, Coolify marks the deploy as failed and rolls back. You can make that health check as thorough as you want — including verifying the LLM path end-to-end.

### Extend `/health` to exercise the real dependencies

Update `main.py` — replace the simple `/health` with a thorough version that actually calls the LLM:

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

### Add a `/ready` endpoint for the shallow check

Some infrastructures want a cheap "am I up" check separate from the deep "am I working" check. Convention:

- `/ready` — cheap, just returns 200 (are we accepting traffic?)
- `/health` — deep, exercises real dependencies (are we actually working?)

```python
@app.get("/ready")
def ready():
    return {"ready": True}
```

Some Coolify configurations let you point liveness at `/ready` and readiness/deep at `/health` separately. Not strictly required for MVP.

## Section 5: GitHub Actions — the 3-job pipeline

Create `.github/workflows/ci.yml`:

```yaml
name: CI/CD

on:
  push:
    branches: [main, staging]
  pull_request:
    branches: [main, staging]

jobs:
  # Job 1 — unit tests + docker build. Runs on every push and every PR.
  # GitHub-hosted runner (public internet) is fine because unit tests don't hit VPN.
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: pip install -r requirements.txt
      - name: Unit tests
        run: pytest tests/ -v
      - name: Docker build
        run: docker build -t sentiment-app .

  # Job 2 — deploy to STAGING. Runs after tests pass, only on push to `staging`.
  # Coolify runs its /health check post-deploy; if /health fails, staging deploy fails.
  deploy-staging:
    needs: test
    if: github.ref == 'refs/heads/staging' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Coolify staging deploy
        run: curl -fsSL -X POST "${{ secrets.COOLIFY_DEPLOY_WEBHOOK_STAGING }}"

  # Job 3 — deploy to PROD. Runs after tests pass, only on push to `main`.
  # By convention, you push to main by merging a PR from staging (which is
  # already deployed + verified via manual QA on the staging URL).
  deploy-prod:
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Coolify prod deploy
        run: curl -fsSL -X POST "${{ secrets.COOLIFY_DEPLOY_WEBHOOK_PROD }}"
```

Key details:

- **`test`** runs everywhere (push + PR, any branch) so failing unit tests never sneak through
- **`deploy-staging`** only fires on `push` to `staging` branch (not PRs) — merging to staging is the trigger. Coolify's health check gates whether the staging deploy is considered successful.
- **`deploy-prod`** only fires on `push` to `main` and only if `test` passed. The typical path: PR from `staging` into `main`, merge → prod deploy.

### 5a. Wire up your repo secrets

Store the two webhook URLs your instructor gave you as **repo secrets**:

1. GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**
2. Create two secrets:
   - `COOLIFY_DEPLOY_WEBHOOK_STAGING` — staging Coolify deploy webhook URL
   - `COOLIFY_DEPLOY_WEBHOOK_PROD` — production Coolify deploy webhook URL

### 5b. Push and watch the pipeline light up

Your repo already has both `main` and `staging` branches (from the template) and the remote is already set (you cloned it in Setup Step 11). Push to `staging` first — you replaced hello-world's code with sentiment code, so this is a big change and staging is where big changes should land first:

```bash
git checkout staging
git add .
git commit -m "replace hello-world with sentiment classifier"
git push
```

Watch:

1. **GitHub Actions tab** → CI/CD workflow runs. Job graph shows `test` → `deploy-staging`.
2. **Coolify UI** — your staging Application shows a new deployment.
3. `curl http://<team-slug>-staging.ml-capstone.cs.byu.edu/health` returns your new `/health` JSON (VPN required).

When staging looks good, promote to prod exactly like the Setup Step 11 walkthrough taught you — PR from `staging` into `main` (or merge locally + push), and `deploy-prod` fires.

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
integration-test.sh   target=http://Group1-staging.ml-capstone.cs.byu.edu
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
# ... edit main.py, add tests/test_emoji.py, verify with pytest and docker locally
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
| Your staging URL | `http://<team-slug>-staging.ml-capstone.cs.byu.edu` |
| Your prod URL | `http://<team-slug>.ml-capstone.cs.byu.edu` |
| GitHub Actions secrets you'll set | `COOLIFY_DEPLOY_WEBHOOK_STAGING`, `COOLIFY_DEPLOY_WEBHOOK_PROD`, `COOLIFY_API_TOKEN` |
| Template repo | `github.com/byu-ml-capstone/hello-world-app` (Use this template) |
| Reference app | `github.com/byu-ml-capstone/sentiment-test-app` |
