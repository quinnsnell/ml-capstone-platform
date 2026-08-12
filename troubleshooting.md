# Troubleshooting

Common failure modes, organized by symptom. If your problem isn't here, escalate to the current admin.

**Related docs:**
- [`student-guide.md`](student-guide.md) — student setup basics
- [`admin-guide.md`](admin-guide.md) — cluster architecture and admin controls
- [`coolify-runbook.md`](coolify-runbook.md) — deep Coolify troubleshooting

---

## Editor / LLM problems

### Chat panel shows an unexpected model (Claude, GPT, etc.) instead of Classroom Chat

You're on a Continue Hub Assistant that shadows your local `~/.continue/config.yaml`. Sign out of Continue Hub:

- Continue side panel → profile icon (bottom-left) → **Sign out**
- Reload VS Code (`Cmd+Shift+P` → **Developer: Reload Window**)
- Check that your assistant is now `Classroom`

### Chat sends but no response comes back

Almost always VPN. Test:

```bash
curl -sS http://ml-capstone.cs.byu.edu:4000/v1/models
```

Should return a JSON list including `classroom-chat` and `classroom-autocomplete`. If it fails:

- Connect / reconnect to `cs-vpn.byu.edu` via GlobalProtect
- Try `nslookup ml-capstone.cs.byu.edu` — expect an internal IP (e.g., `10.55.x.x`)
- If still broken, LiteLLM may be down — see admin section below

### No inline ghost-text (autocomplete)

- Copilot might be enabled and competing with Continue → disable Copilot in this workspace
- Autocomplete model missing from `~/.continue/config.yaml` — verify it has `useLegacyCompletionsEndpoint: true` on the `Classroom Autocomplete` entry
- YAML indentation off — must be 2 spaces, no tabs, `-` list markers aligned under `models:`

### Continue's YAML config doesn't seem to load

- Coolify's UI provider dropdown doesn't include "OpenAI Compatible" as an option — you have to configure via YAML
- File must be at `~/.continue/config.yaml` (not `.json`)
- Signed into Continue Hub? Hub assistants shadow local config; sign out (above)

---

## Deploy / Coolify problems

### Push happened but the app didn't update

Check in order:

1. **GitHub Actions tab** — did the `test` job pass? If red, code is broken. Fix locally, push.
2. **Actions `deploy-prod` job** — did it curl Coolify successfully? A curl error means webhook URL or API token is wrong. Verify repo secrets.
3. **Coolify Deployments tab** — did the deploy fire? If not, check that:
   - Auto Deploy is OFF (should be — deploy path is Actions, not Coolify webhook)
   - `COOLIFY_DEPLOY_WEBHOOK_PROD` secret is the exact URL from Coolify's Webhooks tab
4. **Deployed and marked healthy?** Coolify's health check polls `/health`. If `/health` returns 5xx (LLM unreachable, model failed to load, etc.), the deploy is marked unhealthy and the old version keeps serving.

### App URL returns "Bad Gateway" or Traefik-branded error

Container is running but not reachable from Coolify's proxy. Most common causes:

- App bound to `127.0.0.1` inside container instead of `0.0.0.0` — nothing outside the container can reach it. Fix in `main.py` / `uvicorn` command.
- `EXPOSE` in Dockerfile doesn't match the port Coolify's config expects (usually 8000)
- App crashed on startup — check Coolify's logs

### Build fails at pip install / model download step

Coolify's build container downloads deps fresh each time. Possible issues:

- **Network hiccup** — retry the deploy; usually transient
- **`requirements.txt` mismatch** — a version got yanked from PyPI, or a package rename. Update `requirements.txt`.
- **HF model URL 429 (rate limit)** — HuggingFace occasionally rate-limits. Retry; if persistent, mirror the model in a private location.

### GitHub Actions deploy-prod curl fails with 401

The `COOLIFY_API_TOKEN` secret is wrong or expired. Regenerate the token in Coolify (Keys & Tokens → API Tokens), update the repo secret.

### Container starts but `/health` is 503

The deep health check calls the LLM. If it fails:

- Container can't reach `ml-capstone.cs.byu.edu:4000` — check `LITELLM_URL` env var; it should be `http://ml-capstone.cs.byu.edu:4000/v1` (not `https://` — LLM is HTTP)
- LiteLLM is down or unreachable from Coolify's docker network
- The local HF model failed to load (GPU issue) — check `/gpu` endpoint

---

## Cluster-wide problems (admin)

### One LLM request errors once, then succeeds

Normal. A vLLM engine crashed and LiteLLM routed the retry to the surviving engine on the other GPU host. Investigate `journalctl -u qwen-chat -f` on the affected host.

### All LLM requests time out

Front-end host (rigel) is down or LiteLLM is stopped. Recovery order:

1. `ssh rigel && sudo docker ps | grep litellm` — is the container running?
2. If not: `sudo docker start litellm`; check `sudo docker logs litellm`
3. If persistent: fall back to direct-to-vLLM on castor/pollux (see student guide's fallback section). Notify students to change their `apiBase`.

### Coolify UI unreachable

- rigel:8000 not responding: check `sudo docker ps` on rigel for `coolify` container
- If crashed: `sudo docker restart coolify`; check logs
- If disk full: `sudo docker system prune -af --filter until=168h --volumes`

### Deploys succeed but wrong version is served

Coolify's port mapping or Domain field doesn't match what the app is bound to internally. Confirm:

- Application → Configuration → Advanced → **Ports Mappings** shows the right pair
- Application → Configuration → General → **Domains** contains the group's URL

### GitHub webhook shows "delivered" but Coolify does nothing

- Actions triggered but the workflow's deploy jobs don't fire (check branch — `deploy-prod` only fires on `main`)
- Coolify's Auto Deploy is off AND Actions webhook secret is wrong

### CS IT HAProxy returns EOF on webhook attempts

HAProxy's SNI passthrough rule is misconfigured. See [`tickets/archive/2026-08-07-haproxy-followup.md`](tickets/archive/2026-08-07-haproxy-followup.md) for the diagnostic pattern; re-open a ticket with CS IT if needed.

### Wildcard TLS cert expired

The `*.cs.byu.edu` DigiCert cert is valid Jul 9 2026 → Jan 23 2027. Renewal is via CS IT ticket; see [`coolify-runbook.md`](coolify-runbook.md) §8 (TLS termination) for where the cert files live on rigel.

---

## GPU allocation problems

### `/gpu` shows `cuda_available: false`

The container has no GPU. In Coolify → Application → Configuration → Advanced → **GPU** section:

- Enable GPU
- Set GPU Device Ids (or leave empty for all)
- Save + redeploy

### `nvidia-smi` on rigel shows all 4 GPUs pegged

Multiple groups are running heavy workloads. Options:

- Encourage the biggest offenders to stop when done
- Adjust `CUDA_VISIBLE_DEVICES` on Applications to spread load
- Long-term: deploy a shared inference service for common models (see [`admin-guide.md`](admin-guide.md) on GPU sharing)

---

## Emergency escalations

When to escalate to CS IT vs. self-fix:

| Symptom | Try first | Escalate if |
|---|---|---|
| VPN unreachable | Reconnect, restart GlobalProtect | Widespread — likely CS IT issue |
| Cert about to expire | Renew via CS IT ticket | 30 days before expiry — proactive |
| HAProxy dropping connections | Diagnostic curl (SNI check) | If you can reproduce failure from campus network too |
| Public DNS problems | Verify with `dig @8.8.8.8` | If mismatch persists after ~1 hour |

Everything else — cluster-side issues — the current admin handles.
