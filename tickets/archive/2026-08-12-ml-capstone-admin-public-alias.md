# CS IT ticket — make `ml-capstone-admin.cs.byu.edu` publicly resolvable

**Sent:** 2026-08-12
**Status:** Awaiting CS IT response
**Blocks:** killing the URL-rewrite student-facing footgun (task 40)

## The ask

Make `ml-capstone-admin.cs.byu.edu` publicly resolvable and route it to rigel with SNI passthrough — same treatment as `ml-capstone.cs.byu.edu` already gets.

Two concrete changes:

1. **Public DNS A/CNAME record** for `ml-capstone-admin.cs.byu.edu` → the same public IP that `ml-capstone.cs.byu.edu` resolves to (i.e., CS IT's HAProxy front-end).
2. **HAProxy accepts SNI `ml-capstone-admin.cs.byu.edu`** → forwards to `rigel:443`, matching the existing rule for `ml-capstone.cs.byu.edu`.

## Why

Coolify (self-hosted CI/CD platform running on rigel) generates deploy webhook URLs that include the admin hostname. Students set these URLs as GitHub Actions secrets to trigger auto-deploys on push. GitHub Actions runs on the public internet and cannot currently resolve `ml-capstone-admin.cs.byu.edu` (internal-only) — deploys fail with `curl: (6) Could not resolve host`.

Making the hostname publicly resolvable eliminates a documented URL-rewrite step that every student in the class would otherwise have to remember.

## What we're not asking for

- Additional TLS termination — rigel handles TLS with the `*.cs.byu.edu` wildcard cert CS IT already provided.
- New ACLs, IP-whitelist, or middleware — Coolify's OAuth login gates access (invite-only via `Registration Allowed = OFF`).
- New certs — the `*.cs.byu.edu` wildcard covers `ml-capstone-admin.cs.byu.edu` (one-level subdomain of `cs.byu.edu`).

## Verification steps once CS IT delivers

From any workstation on the public internet:

```bash
# 1. Hostname resolves
nslookup ml-capstone-admin.cs.byu.edu
# expect: same IP as ml-capstone.cs.byu.edu

# 2. HAProxy accepts + forwards
curl -sSL -o /dev/null -w '%{http_code}\n' https://ml-capstone-admin.cs.byu.edu
# expect: 200 (Coolify login page)

# 3. Actual deploy webhook works from off-VPN
# (take a webhook URL from Coolify UI and curl it)
curl -X POST "https://ml-capstone-admin.cs.byu.edu/api/v1/deploy?uuid=<UUID>" -H "Authorization: Bearer <token>"
# expect: 200 with deploy started response
```

## Follow-up doc changes when this ticket resolves

- `student-guide.md` Step 10 — remove the ⚠️ CRITICAL callout about rewriting `ml-capstone-admin.cs.byu.edu` → `ml-capstone.cs.byu.edu`.
- `student-guide.md` Step 11 debugging playbook — remove the `Could not resolve host: ml-capstone-admin.cs.byu.edu` entry.
- Memory: update `coolify_oauth_setup.md` to note both hostnames are publicly reachable.
- Move this ticket file to `tickets/archive/YYYY-MM-DD-ml-capstone-admin-public-alias.md`.

## Notes

- The admin UI becoming publicly reachable is intentional and acceptable — Coolify's OAuth invite-gate blocks all sign-in attempts from non-provisioned users. Only 3 users exist in the DB currently (instructor + co-instructor + one test student).
- If CS IT pushes back on exposing "admin" hostname publicly, fallback is task 40 alt approach: change Coolify's Instance URL to `ml-capstone.cs.byu.edu` (public) — same net effect, requires OAuth callback re-registration.
