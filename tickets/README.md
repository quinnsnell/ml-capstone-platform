# CS IT tickets and coordination

Historical + active tickets we've sent (or plan to send) to BYU CS IT. Kept for reference so future admins can:

- See what infrastructure asks have been made
- Understand the design decisions those tickets encoded
- Reuse language / structure when writing new requests

## Active

_None as of 2026-08-12._

## Archive (resolved or superseded)

Chronological order.

| File | What it asked for | Status |
|---|---|---|
| [`archive/2026-08-05-initial-request.md`](archive/2026-08-05-initial-request.md) | Public HTTPS reverse proxy for GitHub webhook via HAProxy | ✅ Delivered |
| [`archive/2026-08-06-ssl-passthrough-reply.md`](archive/2026-08-06-ssl-passthrough-reply.md) | Our reply confirming SSL passthrough + wildcard cert request | ✅ Cert delivered |
| [`archive/2026-08-07-haproxy-followup.md`](archive/2026-08-07-haproxy-followup.md) | Follow-up: HAProxy accepting but not forwarding SNI | ✅ Fixed |
| [`archive/2026-08-10-ml-capstone-admin-and-wildcard.md`](archive/2026-08-10-ml-capstone-admin-and-wildcard.md) | Admin alias + wildcard `*.ml-capstone.cs.byu.edu` | ✅ Wildcard delivered 2026-08-11; admin alias in follow-up ticket |
| [`archive/2026-08-11-ml-capstone-admin-alias.md`](archive/2026-08-11-ml-capstone-admin-alias.md) | Follow-up: internal DNS alias for `ml-capstone-admin.cs.byu.edu` → rigel | ✅ Delivered 2026-08-11 |
| [`archive/2026-08-12-ml-capstone-admin-public-alias.md`](archive/2026-08-12-ml-capstone-admin-public-alias.md) | Follow-up: make `ml-capstone-admin.cs.byu.edu` publicly resolvable + HAProxy SNI passthrough (kills the URL-rewrite student footgun) | ✅ Delivered 2026-08-12 |

## Notes for future ticket drafts

- **Include reproducers with specific commands and expected outputs.** The HAProxy debugging ticket succeeded quickly because we included the openssl s_client output showing "read 0 bytes written 1560 bytes" — that was the smoking gun.
- **Be explicit about "internal-only" DNS.** BYU CS DNS has a split-horizon; requesting an "internal-only" record is much less scary to IT than "publicly resolvable".
- **Reference the wildcard cert.** CS provides a `*.cs.byu.edu` DigiCert wildcard. Any new hostname one-level under `cs.byu.edu` gets HTTPS via this cert without a new ask. Two-level subdomains (like `admin.ml-capstone.cs.byu.edu`) do NOT get covered — plan hostnames accordingly.
- **Ask for one thing per ticket** if you want it delivered reliably. The 2026-08-10 ticket bundled two asks (admin alias + wildcard); only the wildcard came through, so we had to follow up for the alias.
