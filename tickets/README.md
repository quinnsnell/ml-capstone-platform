# CS IT tickets and coordination

Historical + active tickets we've sent (or plan to send) to BYU CS IT. Kept for reference so future admins can:

- See what infrastructure asks have been made
- Understand the design decisions those tickets encoded
- Reuse language / structure when writing new requests

## Active

| File | What it asks for | Sent |
|---|---|---|
| [`active-ml-capstone-admin-dns.md`](active-ml-capstone-admin-dns.md) | Internal DNS for `ml-capstone-admin.cs.byu.edu` + wildcard `*.ml-capstone.cs.byu.edu` | 2026-08-10 |

## Archive (resolved)

Chronological order.

| File | What it asked for | Status |
|---|---|---|
| [`archive/2026-08-05-initial-request.md`](archive/2026-08-05-initial-request.md) | Public HTTPS reverse proxy for GitHub webhook via HAProxy | ✅ Delivered |
| [`archive/2026-08-06-ssl-passthrough-reply.md`](archive/2026-08-06-ssl-passthrough-reply.md) | Our reply confirming SSL passthrough + wildcard cert request | ✅ Cert delivered |
| [`archive/2026-08-07-haproxy-followup.md`](archive/2026-08-07-haproxy-followup.md) | Follow-up: HAProxy accepting but not forwarding SNI | ✅ Fixed |

## Notes for future ticket drafts

- **Include reproducers with specific commands and expected outputs.** The HAProxy debugging ticket succeeded quickly because we included the openssl s_client output showing "read 0 bytes written 1560 bytes" — that was the smoking gun.
- **Be explicit about "internal-only" DNS.** BYU CS DNS has a split-horizon; requesting an "internal-only" record is much less scary to IT than "publicly resolvable".
- **Reference the wildcard cert.** CS provides a `*.cs.byu.edu` DigiCert wildcard. Any new hostname one-level under `cs.byu.edu` gets HTTPS via this cert without a new ask.
