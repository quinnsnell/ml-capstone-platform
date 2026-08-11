# Classroom AI + CI/CD Cluster

Server-side infrastructure and docs for a shared classroom cluster that gives students:

1. **AI coding assistance** in their editor — chat + inline ghost-text backed by a shared GPU pool (Qwen coder models via vLLM).
2. **A CI/CD platform** — push code to GitHub, run tests in GitHub Actions, and on green tests their app auto-deploys to a URL they can share.

Both capabilities live on a single hostname students remember: **`ml-capstone.cs.byu.edu`**.

Everything runs on the BYU CS network. Only the GitHub webhook path is publicly reachable (via CS IT's HAProxy). The rest — LLM endpoint, admin UIs, deployed apps — requires the BYU CS VPN.

---

## Who is this for?

| You are… | Start here |
|---|---|
| **A student** — want to use the classroom LLM in your editor and/or deploy an app | [`student-guide.md`](student-guide.md) |
| **An admin / instructor** — setting up the cluster or onboarding groups | [`admin-guide.md`](admin-guide.md), then [`onboarding.md`](onboarding.md) |
| **A TA / assistant admin** — helping students hit a wall | [`troubleshooting.md`](troubleshooting.md) |
| **Curious about how it's built** — architecture and design decisions | [`coolify-runbook.md`](coolify-runbook.md) |

---

## Cluster at a glance

Five physical hosts on `.cs.byu.edu`, all VPN-only:

| Host       | GPUs                                     | Role |
|------------|------------------------------------------|------|
| **rigel**  | 4× A6000 (48 GB each)                    | Front-end. Runs LiteLLM (`:4000`), Coolify UI (`:8000`), Coolify's Traefik (`:80`/`:443`), and student app containers |
| **castor** | 1× Blackwell 96 GB + 1× RTX 4090 24 GB   | vLLM chat on Blackwell (`:8000`), vLLM FIM on 4090 (`:8010`) |
| **pollux** | 2× Blackwell 96 GB                       | vLLM chat + FIM (same pattern as castor) |
| **vega**   | 4× RTX 6000 Pro                          | Reserved for TLJH (JupyterHub) for other courses |
| **sirius** | 3× A6000                                 | Unassigned / spare |

Students never see host names — they interact only with `ml-capstone.cs.byu.edu` (and their group URLs under it).

---

## What lives in this repo

```
qwen-coder-cluster/
├── README.md              ← you are here
├── student-guide.md       Student setup: editor + deploy
├── admin-guide.md         Admin setup: cluster install + management
├── coolify-runbook.md     Deep-dive: how the front-end host is built
├── onboarding.md          Admin checklist: add a new student group
├── troubleshooting.md     Common failure modes + fixes
├── scripts/
│   ├── install-qwen-cluster.sh    Idempotent installer for GPU hosts (castor, pollux)
│   ├── uninstall-qwen-cluster.sh  Reverse of the above
│   ├── verify-qwen-host.sh        Health check on a GPU host post-install
│   └── smoke-test-cluster.sh      End-to-end smoke test (run from your laptop over VPN)
├── tickets/
│   ├── active-*.md        Open coordination tickets with CS IT
│   └── archive/           Historical / resolved tickets
└── (see also: github.com/quinnsnell/sentiment-test-app — reference app; clone separately)
```

---

## Public endpoints

| Purpose | URL | Reachable from |
|---|---|---|
| Editor endpoint for the classroom LLM | `http://ml-capstone.cs.byu.edu:4000/v1` | VPN |
| GitHub webhook (auto-deploy) | `https://ml-capstone.cs.byu.edu/webhooks/*` | Public internet (via CS IT HAProxy) |
| Coolify API (deploy trigger from GitHub Actions) | `https://ml-capstone.cs.byu.edu/api/v1/deploy` | Public internet, token-gated |
| Coolify admin UI | `https://ml-capstone-admin.cs.byu.edu` | VPN (planned — waiting on DNS) |
| Student group apps | `https://<group>.ml-capstone.cs.byu.edu` | VPN |

Model aliases exposed by LiteLLM:

- `classroom-chat` — chat and agentic edits (Qwen3-Coder)
- `classroom-autocomplete` — inline FIM ghost-text (Qwen2.5-Coder-7B)

---

## What's live vs. planned

**Working end-to-end today:**
- LiteLLM proxy on rigel:4000 (pools castor + pollux)
- Coolify with GitHub App + tests-gate-deploy pipeline
- Reference app at [`github.com/quinnsnell/sentiment-test-app`](https://github.com/quinnsnell/sentiment-test-app) — dual-model (LLM + local HF) demo
- Cluster smoke test hits 14/14

**Planned:**
- `ml-capstone-admin.cs.byu.edu` DNS + Coolify OAuth (see [`tickets/active-ml-capstone-admin-dns.md`](tickets/active-ml-capstone-admin-dns.md))
- Self-serve Coolify accounts per student group (via GitHub OAuth once admin DNS is up)
- Per-group DNS wildcard `*.ml-capstone.cs.byu.edu`
- Self-hosted GitHub Actions runner (for integration tests against staging URLs)

---

## Quick smoke test

From your laptop on VPN:

```bash
./scripts/smoke-test-cluster.sh
```

Runs 14 checks against LiteLLM, direct-to-vLLM (castor + pollux), Coolify UI, and the deployed reference app. All green means the cluster is healthy.

---

## Contributing / making changes

This repo tracks classroom infrastructure. Small documentation edits can be PRs; anything touching the cluster (scripts, Coolify config) should be coordinated with the current admin.

**Never commit:** cert bundles, private keys, `.env` files with real values. The `.gitignore` blocks the usual suspects but be careful about pasting URLs with embedded tokens into docs.
