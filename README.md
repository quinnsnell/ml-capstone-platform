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
ml-capstone-platform/
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
│   ├── smoke-test-cluster.sh      End-to-end smoke test (run from your laptop over VPN)
│   ├── provision-teams.sh         Bulk-create Coolify teams+users+servers from roster CSV (runs on rigel)
│   ├── invite-to-org.sh           Invite roster users to the byu-ml-capstone GitHub org (runs on laptop)
│   └── provision-gh-teams.sh      Create GitHub Teams mirroring Coolify teams + add members (runs on laptop)
├── sentiment-test-app/    Reference app: LLM + local HF, base+app Docker split, integration tests
├── tickets/
│   ├── active-*.md        Open coordination tickets with CS IT
│   └── archive/           Historical / resolved tickets
└── roster-*.csv           Class rosters — provision-teams.sh reads these
```

---

## Public endpoints

| Purpose | URL | Reachable from |
|---|---|---|
| Editor endpoint for the classroom LLM | `http://ml-capstone.cs.byu.edu:4000/v1` | VPN |
| GitHub webhook (auto-deploy) | `https://ml-capstone.cs.byu.edu/webhooks/*` | Public internet (via CS IT HAProxy) |
| Coolify API (deploy trigger from GitHub Actions) | `https://ml-capstone.cs.byu.edu/api/v1/deploy` | Public internet, token-gated |
| Coolify admin UI | `https://ml-capstone-admin.cs.byu.edu` | VPN |
| Student group apps | `https://<group>.ml-capstone.cs.byu.edu` | VPN |

Model aliases exposed by LiteLLM:

- `classroom-chat` — chat and agentic edits (Qwen3-Coder)
- `classroom-autocomplete` — inline FIM ghost-text (Qwen2.5-Coder-7B)

---

## What's live vs. planned

**Working end-to-end today:**
- LiteLLM proxy on rigel:4000 (pools castor + pollux)
- Coolify with GitHub App + tests-gate-deploy pipeline
- Wildcard DNS `*.ml-capstone.cs.byu.edu` → rigel (delivered 2026-08-11) — group URLs resolve automatically
- Coolify admin UI at `https://ml-capstone-admin.cs.byu.edu` with GitHub OAuth (invite-gated via `Registration Allowed=off`)
- Self-serve Coolify Teams per student/group via `scripts/provision-teams.sh` (reads a roster CSV, seeds users + teams + servers)
- Two starter apps: [`hello-world-app`](https://github.com/byu-ml-capstone/hello-world-app) (template repo — minimal FastAPI for the Coolify onboarding lab) and `sentiment-test-app/` (LLM + local HF reference)
- Cluster smoke test hits 14/14

**Planned:**
- Self-hosted GitHub Actions runner for integration tests against staging URLs (Phase 18)
- Team cleanup / reset script (Phase 21)

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
