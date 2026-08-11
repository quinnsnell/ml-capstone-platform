# Ask CS sysadmins: internal DNS for `ml-capstone-admin.cs.byu.edu`

> **Outcome (2026-08-11):** CS IT delivered the wildcard `*.ml-capstone.cs.byu.edu` → rigel. They did NOT add `ml-capstone-admin.cs.byu.edu` as an alias — a follow-up ticket ([`../active-ml-capstone-admin-alias.md`](../active-ml-capstone-admin-alias.md)) was sent for that specifically.

---

Hi,

One quick internal-DNS ask to round out the ml-capstone classroom cluster.

## What I'd like

Add an **internal-only** A record:

- **Hostname:** `ml-capstone-admin.cs.byu.edu`
- **Target IP:** same as `ml-capstone.cs.byu.edu` currently resolves to internally (`10.55.10.70` or whatever rigel resolves to)
- **Scope:** internal (VPN) DNS only — not public

## Why

This is the hostname students and instructors will use for the classroom Coolify admin UI + OAuth sign-in. Decoupling the admin URL from the specific machine name (`rigel.cs.byu.edu`) means if we ever move Coolify to a different host, only the DNS record needs to change — no student re-training, no OAuth re-registration.

Everything about it stays inside the CS VPN — public users get no answer. The existing `*.cs.byu.edu` wildcard cert covers the hostname (one level deep), so we can terminate TLS on it with the same cert we already installed for `ml-capstone.cs.byu.edu`.

## Related, if you want to bundle

While you're in the zone file, I'll eventually also want:

- `*.ml-capstone.cs.byu.edu` → same internal IP as `ml-capstone.cs.byu.edu` (for per-group student app URLs like `Group1.ml-capstone.cs.byu.edu`). Wildcard entries can wait; students can use `/etc/hosts` as a stopgap in the meantime, but the wildcard would be much cleaner if it's easy on your side.

Thanks!
— Quinn
