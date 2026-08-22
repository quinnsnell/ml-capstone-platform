# `POST /applications/private-github-app` returns 404 for system-wide GitHub Apps when called with a non-root-team token

**Status:** Filed as [coollabsio/coolify#11449](https://github.com/coollabsio/coolify/issues/11449) on 2026-08-21; fix proposed in [PR #11451](https://github.com/coollabsio/coolify/pull/11451) (verified against running v4.3.7)
**Filed by:** @quinnsnell
**Date drafted:** 2026-08-21

---

## Summary

`POST /api/v1/applications/private-github-app` ignores the `is_system_wide`
flag on GitHub App sources. When the calling API token belongs to a non-root
team, the endpoint responds `404 Github App not found` even though the same
GitHub App is (a) marked `is_system_wide = true` and (b) usable from that
team's UI to create the exact same Application.

This makes team-scoped API tokens unable to create Applications backed by any
GitHub App that lives in Root Team — which, for an org-wide App source, is
where it normally lives.

## Environment

- **Coolify version:** `v4.3.7` (running); bug is also present on `main` at HEAD (2026-08-21)
- **Deployment:** self-hosted, single node
- **API endpoint:** `https://ml-capstone-admin.cs.byu.edu/api/v1`
- **GitHub App source:** `byu-ml-capstone-coolify`, created in Root Team, with
  `is_system_wide = true` so every team can see it in the **Sources** dropdown.
- **Calling token:** team-scoped API token from a non-root team (permissions:
  view + create + deploy). The team's own user *can* create the same Application
  via the UI.

## Reproduction

Minimal repro without Terraform, using the raw REST endpoint:

```bash
curl -X POST https://<coolify-host>/api/v1/applications/private-github-app \
  -H "Authorization: Bearer <TEAM_SCOPED_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "project_uuid":     "<team-project-uuid>",
    "environment_uuid": "<team-env-uuid>",
    "server_uuid":      "<server-uuid>",
    "destination_uuid": "<destination-uuid>",
    "github_app_uuid":  "<is_system_wide=true App uuid, owned by Root Team>",
    "git_repository":   "byu-ml-capstone/qsnell-hello",
    "git_branch":       "staging",
    "build_pack":       "dockercompose",
    "ports_exposes":    "8000"
  }'
```

Response:

```
HTTP/1.1 404 Not Found
{"message":"Github App not found."}
```

Same call succeeds if `TEAM_SCOPED_TOKEN` is replaced with a Root Team token,
even though nothing about the target project/env/server is changed.

Same behavior via Terraform with `bindtech-xyz/coolify` `0.1.2`:

```hcl
resource "coolify_application" "hello_staging" {
  project_uuid     = coolify_project.app.uuid
  environment_uuid = coolify_environment.staging.uuid
  server_uuid      = "<server-uuid>"
  destination_uuid = "<destination-uuid>"
  github_app_uuid  = "<system-wide App uuid>"
  git_repository   = "byu-ml-capstone/qsnell-hello"
  git_branch       = "staging"
  build_pack       = "dockercompose"
  ports_exposes    = "8000"
}
```

`terraform apply` fails on this resource with the same underlying 404. The
sibling `coolify_project` and `coolify_environment` resources apply cleanly
with the same team token — the failure is specifically the GitHub App lookup
inside `applications/private-github-app`.

## Expected behavior

If a GitHub App source has `is_system_wide = true`, any team's token should
be able to reference it by UUID on Application create — matching UI behavior
where that same team can already select it from the Sources dropdown.

## Actual behavior

The endpoint's App lookup is scoped strictly to the caller's team without
consulting `is_system_wide`. Result: `404 Github App not found` for any
non-root team, even for Apps explicitly marked as system-wide.

Confirmed via direct HTTP call, so this is not a Terraform provider issue.

### Root cause (from source)

`app/Http/Controllers/Api/ApplicationsController.php` on `main` (as of
2026-08-21, sha reachable at that path):

```php
// line ~1608
$githubApp = GithubApp::whereTeamId($teamId)
    ->where('uuid', $githubAppUuid)
    ->first();
if (! $githubApp) {
    return response()->json(['message' => 'Github App not found.'], 404);
}
```

The `whereTeamId($teamId)` clause is unconditional — there's no
`orWhere('is_system_wide', true)`. Any GitHub App whose owning team differs
from the calling token's team is treated as "not found," regardless of the
`is_system_wide` flag.

Contrast with the UI's team-lookup path
(`app/Models/Team.php::githubApps()`), which was fixed for the analogous UI
bug in [#2643](https://github.com/coollabsio/coolify/issues/2643) and does
honor `is_system_wide`. The API's create-Application handler was not updated
to match.

## Impact

We run a class where each student team gets a Coolify team. We want a single
`terraform apply` to provision the whole team stack — Project, Environments,
GitHub-App-backed Applications, GitHub Actions secrets — from the student's
own team token. Because this endpoint 404s on system-wide Apps, the Terraform
lab has to stop short of creating the Applications; students finish the
wiring in the UI. See
[`testing/qsnell-hello/terraform/README.md`](../../testing/qsnell-hello/terraform/README.md)
for how the lab currently splits Terraform vs. manual steps because of this bug.

The alternatives are worse:

- **Root token in every student's Terraform state** — gives every student
  root over the whole Coolify instance. Non-starter.
- **Bypass the API and INSERT directly into Postgres** — what our
  `scripts/provision-teams.sh` admin script does. Fragile across Coolify
  version bumps; we've already had one schema-drift incident this term.

## Suggested fix

Change the lookup at `ApplicationsController.php:~1608` to accept either
same-team or system-wide Apps, mirroring the UI's team-scoped query:

```php
$githubApp = GithubApp::where('uuid', $githubAppUuid)
    ->where(function ($q) use ($teamId) {
        $q->where('team_id', $teamId)
          ->orWhere('is_system_wide', true);
    })
    ->first();
```

The same fix likely needs to be applied to any sibling handlers that resolve
`github_app_uuid` (e.g., the deploy-key / preview-deployment paths) — a grep
for `whereTeamId(` next to `github` should surface them.

If team-scoped tokens are *intended* to be blocked from system-wide Apps
(seems unlikely given the UI already permits it), at minimum:

1. Return `403` with a clearer message (e.g., `"GitHub App is system-wide;
   Application create from a team-scoped token is not permitted"`) rather than
   a misleading `404 Github App not found`.
2. Document the restriction, since it contradicts UI capability.

## Related issues (for maintainer context)

- [#2643 — System Wide GitHub Apps does not work](https://github.com/coollabsio/coolify/issues/2643) (closed 2025-01-17). Fixed the UI-side manifestation of this bug in `Team::githubApps()`. The API's create-Application handler was not updated in the same pass, which is what this report tracks.
- [#4864 — github_app_uuid & SecurityKey.uuid are different](https://github.com/coollabsio/coolify/issues/4864) (closed 2026-08-20). Same `"Github App not found."` error string but a different root cause (callers were fetching the wrong UUID from `/security/keys`). Resolved by exposing `GET /api/v1/github-apps`. Our repro uses the correct UUID from that endpoint and still 404s.
- [#3209 — Unable to Identify github_app_uuid](https://github.com/coollabsio/coolify/issues/3209) (closed 2024-12-04). Predecessor of #4864.

## Attachments to include when filing

- [ ] Redacted `curl -v` or `terraform apply` output showing the 404.
- [ ] Coolify version (`<FILL IN>`) from **Settings → Instance**.
- [ ] Screenshot of the same team's UI showing the App in the Sources dropdown
      (proves `is_system_wide` is honored by the UI).
