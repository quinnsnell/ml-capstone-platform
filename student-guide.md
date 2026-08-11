# Classroom AI Cluster — Student Setup Guide

Your class has access to a shared **AI + CI/CD cluster** at `ml-capstone.cs.byu.edu`. It gives you two things:

1. **AI coding assistance** — chat and inline autocomplete in your editor, powered by the class's shared GPU cluster (Qwen coder models).
2. **CI/CD platform** — push code to GitHub, run tests in GitHub Actions, and on green tests your app auto-deploys to a URL you can share.

You can use either capability or both. This guide walks you through setting up each.

## Before you start

**Install GlobalProtect and connect to the CS VPN** — the cluster is on the CS network. Only one URL (the GitHub webhook path) is reachable from the public internet; everything else, including the LLM endpoint and your deployed apps, requires VPN.

- VPN gateway: `cs-vpn.byu.edu`
- Client: GlobalProtect (BYU IT has installers and instructions)

Also make sure you have:

- A **GitHub account** (you'll deploy from a repo in your account, not a class org)
- **Docker installed locally** (for testing your app before pushing)
- **VS Code** or another editor of your choice

Your instructor will provide:

- **Two Coolify Deploy Webhook URLs** — one for staging, one for production. Your group uses these in your GitHub Actions workflow to trigger deploys.
- **Two hostnames** — one for your group's staging environment (`<your-group>-staging.ml-capstone.cs.byu.edu`) and one for production (`<your-group>.ml-capstone.cs.byu.edu`). Examples throughout this guide use `Group1` as the placeholder — substitute your group's actual name.

If `<your-group>.ml-capstone.cs.byu.edu` doesn't resolve when you're on VPN, your instructor may not yet have wildcard DNS set up. In that case add these two lines to your local `/etc/hosts` (macOS/Linux) or `C:\Windows\System32\drivers\etc\hosts` (Windows):

```
10.55.10.70   Group1.ml-capstone.cs.byu.edu
10.55.10.70   Group1-staging.ml-capstone.cs.byu.edu
```

(Confirm the IP with `nslookup rigel.cs.byu.edu` while on VPN — it should return that address.)

Everything below runs off `ml-capstone.cs.byu.edu`. Once you're on VPN, that hostname resolves to the classroom cluster on rigel.

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

- Two Coolify Applications for your group's repo — one watching `staging`, one watching `main`
- DNS records for your group's hostnames (or one wildcard record covering all groups)
- Two Coolify Deploy Webhook URLs your group uses as GitHub Actions secrets
- Env vars for both environments (they may differ — e.g., use a smaller model in staging)

**What your group does:**

- Create a shared GitHub repo (your group owner's account or the class org — either works)
- Write your app + Dockerfile + unit tests
- Make your `/health` endpoint thorough enough to double as an automated smoke test (Section 4)
- Add a GitHub Actions workflow with the three jobs above
- Follow the branch flow: feature branch → PR to `staging` → PR to `main`

> **Roadmap note.** Automated integration tests running from GitHub Actions against the live staging URL (Vercel-style Preview Deploys with full pytest) require a self-hosted runner inside the CS VPN. That's on the roadmap for once the class grows. For now, Coolify's health check + manual QA of the staging URL fills the gap.

## Why staging + prod?

Real teams never merge straight into production. Staging exists to:

- **Catch bugs that only appear against real infrastructure** — networking, env vars, actual database, real dependencies
- **Let integration tests hit a live URL** — unit tests can't verify "did my LLM prompt actually work end-to-end"
- **Give reviewers something clickable** — before merging to prod, someone visits the staging URL and sanity-checks
- **Provide a rollback safety net** — if prod breaks after a merge, you can roll back knowing staging worked

This mirrors what you'll do at every serious tech company.

## Section 1: Build your first deployable app

Let's build a small text-analysis service that uses the classroom LLM. Same pattern as the reference `sentiment-test-app` — you'll build it from scratch to see every piece.

### 1a. Create the repo

```bash
mkdir sentiment-app
cd sentiment-app
git init -b main
```

### 1b. Write `main.py`

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

### 1c. Write `requirements.txt`

```
fastapi==0.115.6
uvicorn[standard]==0.34.0
httpx==0.28.1
pydantic==2.10.5
```

### 1d. Write the `Dockerfile`

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

### 1e. Write a `.gitignore`

```gitignore
__pycache__/
*.pyc
.venv/
venv/
.env
.env.local
.pytest_cache/
```

### 1f. Add a `.env` for local development

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

```bash
git add .
git commit -m "initial sentiment app + CI/CD"
git branch staging                              # create staging branch tracking main
git remote add origin https://github.com/<your-username>/sentiment-app.git
git push -u origin main
git push origin staging                         # push staging too
```

First run on `main` triggers `test` + `deploy-prod`. On subsequent development you'll typically push to `staging` first (see Section 7). Watch:

1. **GitHub Actions tab** → CI/CD workflow runs. Job graph shows `test` → `deploy-prod`.
2. **Coolify UI** (instructor can share) → sentiment-app prod deploys.
3. `curl http://Group1.ml-capstone.cs.byu.edu/health` returns your `/health` JSON. (VPN required.)

## Section 6: Making your deploys fast (when they get slow)

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

The classroom's reference app — `github.com/quinnsnell/sentiment-test-app` — implements this pattern end-to-end. Its README's "How this app is packaged (and why)" section has:

- Exact file contents for `Dockerfile.base`, `Dockerfile`, and the base-build workflow
- Actual performance numbers (before/after)
- A table of where docker caches live in different parts of the CI/CD pipeline
- More on why the pattern works and when it doesn't

Read that once, especially if your project imports torch or transformers. It'll save you real time.

## Section 7: The day-to-day update–test–PR–deploy workflow

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
- `deploy-staging` (Coolify deploys to your staging URL)
- `integration-tests` (self-hosted runner hits live staging URL with pytest)

If integration tests pass, you know the deploy actually works against real infrastructure.

### Step 5 — Open a "promotion" PR from `staging` into `main`

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

### Rollback

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
- **In local dev:** use the `.env` file pattern from Section 1f.
- **In your code:** read via `os.environ["LITELLM_URL"]` (Python) or `process.env.LITELLM_URL` (Node), etc.

Full working example: `github.com/quinnsnell/sentiment-test-app`.

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
| Your staging URL | `Group1-staging.ml-capstone.cs.byu.edu` |
| Your prod URL | `Group1.ml-capstone.cs.byu.edu` |
| GitHub Actions secrets you'll set | `COOLIFY_DEPLOY_WEBHOOK_STAGING`, `COOLIFY_DEPLOY_WEBHOOK_PROD` |
| Reference app | `github.com/quinnsnell/sentiment-test-app` |
