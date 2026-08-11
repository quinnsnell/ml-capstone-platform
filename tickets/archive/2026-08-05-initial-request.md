# CS IT ticket — reverse proxy + internal DNS for ml-capstone.cs.byu.edu

Draft for the CS IT sysadmins. Copy into their ticket system / email / whatever channel they prefer.

---

**Subject:** Reverse proxy and internal DNS setup for `ml-capstone.cs.byu.edu` → `rigel.cs.byu.edu`

Hi,

I'm setting up a classroom deployment platform on `rigel.cs.byu.edu` (Coolify + LiteLLM + Docker). Students will push code to per-student GitHub repos and their apps will auto-deploy on rigel. This needs two things from you:

## 1. Public HTTPS reverse proxy for the GitHub webhook

Please forward:

- **From (public):** `https://ml-capstone.cs.byu.edu/webhooks/*`
- **To (campus):** `http://rigel.cs.byu.edu:8000/webhooks/*`

Details:

- TLS terminated at your proxy using the existing `.cs.byu.edu` cert
- Preserve HTTP method (POST), path, headers (especially `X-Hub-Signature-256`), and request body — this is a straight HTTP-level reverse proxy, not a TCP passthrough
- Anything outside the `/webhooks/*` path may be 404'd at your edge — the Coolify UI on rigel:8000 should stay off the public internet
- No inbound firewall rule needed on rigel; it's already listening on `:8000` on the campus network

**Purpose:** GitHub's servers deliver push-event webhooks to this URL. Coolify on rigel receives them and triggers auto-deploy of the student's app. This is the only public entry point in the whole design — everything else stays VPN-only.

**Verification:** once set up, from the public internet:

```bash
curl -sS -X POST -o /dev/null -w '%{http_code}\n' \
    https://ml-capstone.cs.byu.edu/webhooks/source/github/events
```

Expected: `200` (Coolify's webhook receiver returns 200 for any POST, including empty ones — real signature validation happens after acceptance). If you get 200, the reverse proxy is up and reaching Coolify successfully. A HEAD/GET returns `302` (Coolify's SPA fallback) — that's fine, just don't use HEAD/GET for the verification.

## 2. Internal DNS records for student app hostnames

Please add the following A records that resolve to `rigel.cs.byu.edu`'s IP:

- `testQ.ml-capstone.cs.byu.edu` → rigel IP
- `testM.ml-capstone.cs.byu.edu` → rigel IP

These are for the first two test apps. As the class ramps up, I'll come back with additional per-student records — please treat this as an ongoing coordination rather than a one-shot request. (If you'd rather set up a wildcard `*.ml-capstone.cs.byu.edu` → rigel that would work too, but per-student records are fine.)

Details:

- **Internal-only DNS is sufficient** — these hosts are accessed via VPN, so they don't need to resolve from the public internet. Whichever internal DNS view you already run for campus resources is fine.
- **No TLS needed on these** — student apps serve HTTP directly, and browser traffic is already private via the VPN.
- **No reverse proxy needed on these** — the DNS record just needs to resolve to rigel's IP. Coolify's built-in Traefik on rigel handles the hostname-based routing to the right container.

Thanks — happy to hop on a call or answer questions if any of this needs clarifying.

— Quinn

---

## Reference material (for our own records, don't send to CS IT)

**Coolify Instance Domain** must be set to `ml-capstone.cs.byu.edu` in the Coolify UI so it generates app URLs like `<student>.ml-capstone.cs.byu.edu`.

**GitHub App webhook URL** (used in Phase 13 GitHub App creation): `https://ml-capstone.cs.byu.edu/webhooks/source/github/events`

**When adding a new student mid-semester,** the coordination is: (a) ask CS IT to add `<name>.ml-capstone.cs.byu.edu` → rigel IP, (b) create the Coolify Application resource pointing at their repo. Then their `git push` works.

**Failure modes this introduces:**
- CS IT proxy down → GitHub webhooks stop delivering. Existing deployed apps keep serving. Manual redeploy still works from Coolify UI (VPN).
- CS IT DNS down → all student apps unreachable (but Coolify + LiteLLM still work since they're accessed via rigel's hostname directly, not through DNS delegation).
