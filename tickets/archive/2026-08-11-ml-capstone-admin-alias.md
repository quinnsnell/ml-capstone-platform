# Follow-up: internal DNS alias for `ml-capstone-admin.cs.byu.edu`

Sent 2026-08-11 after the wildcard was delivered.

---

Hi,

Thanks for the wildcard — it's live and working (`Group1.ml-capstone.cs.byu.edu` etc. all resolve correctly). One remaining ask from the previous ticket that didn't come through:

## What I need

Add an **internal-only** A record (or CNAME alias):

- **Hostname:** `ml-capstone-admin.cs.byu.edu`
- **Target:** `rigel.cs.byu.edu` (or its IP, `10.55.10.70`)
- **Scope:** internal (VPN) DNS only

## Why this one specifically, not just the wildcard

The wildcard covers `*.ml-capstone.cs.byu.edu` (two-level subdomains under `cs.byu.edu`). Great for student app URLs.

But the Coolify admin UI needs HTTPS for GitHub OAuth to work, and the existing `*.cs.byu.edu` DigiCert wildcard only covers **one-level** subdomains under `cs.byu.edu` (e.g., `ml-capstone-admin.cs.byu.edu` ✅, but `admin.ml-capstone.cs.byu.edu` ❌ — cert wouldn't validate).

So we need this specific hostname pattern to get valid TLS on the admin UI without asking for a new cert.

## For the ticket record

The two hostnames serve different roles:

- `*.ml-capstone.cs.byu.edu` (delivered) → per-group student app URLs (HTTP-over-VPN is fine)
- `ml-capstone-admin.cs.byu.edu` (this ask) → Coolify admin UI (needs HTTPS via existing wildcard cert)

Thanks!
— Quinn
