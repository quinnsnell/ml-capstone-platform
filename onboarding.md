# Admin checklist — onboarding the class

This is the term-start procedure to onboard students, whether they're doing individual sandbox work or forming groups later. Follow top to bottom.

Everything past prerequisites is script-driven — students self-provision their Applications in Coolify. The instructor only runs three scripts once per term, plus a few `gh api` calls as groups form.

---

## Prerequisites — one-time or per-term setup

Before you onboard anyone, verify the following are live (most of these were set up during the initial cluster build — see [`admin-guide.md`](admin-guide.md) and [`coolify-runbook.md`](coolify-runbook.md) for how):

- The cluster is healthy — run `./scripts/smoke-test-cluster.sh` (14/14 expected)
- Coolify admin UI reachable at `https://ml-capstone-admin.cs.byu.edu` (public via CS IT HAProxy; gated by OAuth invite-only signin)
- Wildcard DNS `*.ml-capstone.cs.byu.edu` → rigel is live
- The `byu-ml-capstone` GitHub org exists with you (and ideally a co-instructor) as Owners
- The `byu-ml-capstone-coolify` GitHub App is installed on the org with All Repositories access
- Coolify's `byu-ml-capstone-coolify` Source is configured System-Wide
- The `byu-ml-capstone/hello-world-app` template repo exists and is marked as a Template
- Registration Allowed = OFF in Coolify Settings → Advanced (invite-only OAuth)
- `gh` CLI installed and authenticated as an org Owner (`gh auth refresh -h github.com -s admin:org` if you need admin scope)

---

## Term-start: run the three provisioning scripts

Everything reads the same **roster CSV** with columns `team_name,email,name,github_username`. See `roster-example.csv` for the shape. Each script is idempotent — safe to re-run whenever the roster grows.

> **All three scripts default to preview mode.** Running without `--apply` shows what it *would* do (per-row plan + rollup) without making any changes. Always run the preview first, sanity-check the plan, then re-run with `--apply` to execute. This is safer than dry-run flags on some tools because the preview is the *actual* SQL / API calls the apply will make — not an approximation.
>
> All three read the newest `roster-*.csv` in the current directory if you omit `--roster`. Explicit `--roster` is recommended when multiple rosters coexist.

Rosters are gitignored except `roster-example.csv` (FERPA — real emails + GitHub usernames must never enter public git history). Keep them on rigel; `scp` from your laptop as needed.

### 1. Send GitHub org invitations

Preview first:
```bash
./scripts/invite-to-org.sh --roster roster-2026-fall.csv
```

Sanity-check the plan (should show one line per row: `INVITE <gh_user>` or `SKIP (already member)`). Then apply for real:
```bash
./scripts/invite-to-org.sh --roster roster-2026-fall.csv --apply
```

Students receive an email and GitHub notification. They must accept before step 2 can add them to Teams.

### 2. Wait for acceptance, then create GitHub Teams

Wait a day (or set a syllabus deadline: "accept the org invite by Friday"). Then preview:
```bash
./scripts/provision-gh-teams.sh --roster roster-2026-fall.csv
```

Confirm each team's slug + expected member list. Then apply:
```bash
./scripts/provision-gh-teams.sh --roster roster-2026-fall.csv --apply
```

Creates one GitHub Team per unique `team_name` in the roster (slug = `slugify(team_name)`) and adds each roster row's `github_username` to their team.

### 3. Create Coolify teams, users, servers, destinations

Runs on rigel — needs docker access to the `coolify-db` container. Add your user to the `docker` group once (`sudo usermod -aG docker snell` + re-login) so future runs don't need `sudo`. If your rigel `roster-*.csv` is out of date, `scp` it up first.

**Step 3a — schema check (once per term, or after Coolify auto-upgrades).** `provision-teams.sh` writes directly to Coolify's Postgres. Coolify may have auto-updated past the versions this script has been proven against, and a column rename/removal would silently mis-provision teams. Always run this first:

```bash
ssh rigel 'cd ~/ml-capstone-platform && git pull && ./scripts/provision-teams.sh --check-schema'
```

Look at the first line under `PREFLIGHT`. It prints one of:
- `Coolify version: X.Y.Z (known-good; script proven against 4.2.x, 4.3.x)` → safe to proceed.
- `Coolify version: X.Y.Z (untested; script proven against ...)` → **stop**. Diff the dumped table schemas against `REQUIRED_COLS` in `scripts/provision-teams.sh`. If all our columns are still present with compatible types, add the new minor to `KNOWN_GOOD_MAJOR_MINORS` and try again.

**Step 3b — preview the roster provisioning:**
```bash
ssh rigel 'cd ~/ml-capstone-platform && ./scripts/provision-teams.sh --roster roster-2026-fall.csv'
```

The per-row plan shows CREATE/EXISTS for each of the 6 tables (users, teams, team_user, servers, server_settings, standalone_dockers), plus a cleanup phase that deletes redundant auto-created personal teams for roster users. Add `--show-sql` to print the exact SQL that would run.

**Step 3c — apply:**
```bash
ssh rigel 'cd ~/ml-capstone-platform && ./scripts/provision-teams.sh --roster roster-2026-fall.csv --apply'
```

The script runs preflight → plan → apply → verify in one transactional batch. If any preflight fails, it aborts cleanly without touching state. If the post-apply verify fails, it exits non-zero so you notice.

### 4. Smoke-test everything before handing off to students

Run the verifier on rigel (read-only, no `--apply` — it's a pure check):

```bash
ssh rigel 'cd ~/ml-capstone-platform && ./scripts/verify-provisioning.sh --roster roster-2026-fall.csv'
```

For each roster row it runs 9 checks against **both** GitHub and Coolify's DB:

- **GitHub** — org membership, team exists, team membership
- **Coolify DB** — users row, teams row, team_user pivot, `ml-capstone` server attached, `server_settings` has a valid encrypted `sentinel_token`, `standalone_dockers` destination on the `coolify` network

Output modes:
- default — compact one-line-per-row table (right for a full class)
- `--verbose` — grouped block per person with each check labeled (right for a single row or when a row failed and you need detail)

Exit code is 0 if every row passed every check; non-zero if any row missed any artifact.

**Then walk the manual UI checklist the script prints at the end.** For each unique team it lists:

1. Sign into `https://ml-capstone-admin.cs.byu.edu` as yourself, then temporarily add yourself to the team as an admin so the team switcher shows it (one-liner in the checklist output):
   ```bash
   docker exec -i coolify-db psql -U coolify -d coolify -c "INSERT INTO team_user (team_id, user_id, role, created_at, updated_at) SELECT t.id, u.id, 'admin', NOW(), NOW() FROM teams t, users u WHERE t.name = '<team_name>' AND u.email = '<your_email>' ON CONFLICT DO NOTHING;"
   ```
2. Refresh Coolify, switch to that team, and walk:
   - **Servers → ml-capstone** — server-show page loads without a 500 (this is where the encrypted `sentinel_token` bug bit us; if this page renders, existing rows are compatible with the current Coolify version)
   - **Projects → + New Project** (throwaway name) → into production env → **+ Add Resource → Private Repository (with GitHub App)** and confirm Screens 1-3: destination `coolify` pickable, source `byu-ml-capstone-coolify` pickable, org repos load including `hello-world-app`. Bail on Screen 4.
   - Delete the throwaway Project (Danger Zone).
3. Remove yourself from the team so it's clean for the student:
   ```bash
   docker exec -i coolify-db psql -U coolify -d coolify -c "DELETE FROM team_user WHERE team_id = (SELECT id FROM teams WHERE name='<team_name>') AND user_id = (SELECT id FROM users WHERE email='<your_email>');"
   ```

The UI walkthrough is manual because Coolify's Livewire pages need a real browser session — no CLI substitute exists. Once per unique team, before turning students loose.

---

## What students do after the scripts run

Students follow [`student-guide.md`](student-guide.md) → Part B → **Setup: Sign in and create your Coolify Applications**. In summary:

1. Sign in to Coolify at `https://ml-capstone-admin.cs.byu.edu` via GitHub OAuth (email matches roster)
2. Switch to their pre-provisioned Coolify team
3. Create a Project → prod + staging Environments
4. Use `github.com/byu-ml-capstone/hello-world-app` "Use this template" → owner = `byu-ml-capstone`, name = `<team-slug>-<app>`
5. In Coolify: Application creation → destination `coolify` → source `byu-ml-capstone-coolify` → their repo → main/staging branch
6. Set domain to `<team-slug>.ml-capstone.cs.byu.edu` (prod) or `<team-slug>-staging.ml-capstone.cs.byu.edu` (staging)
7. Turn off Coolify Auto Deploy on both Applications
8. Copy each Application's Deploy Webhook URL
9. Create a Coolify API token (deploy scope)
10. Paste 3 secrets into their GitHub repo settings
11. First push → GitHub Actions → deploy

The instructor does NOT create Applications or Deploy Webhooks. Students do this per the guide.

---

## Off-boarding a group / student (end of semester)

1. **Coolify:** delete the team via UI → Team → Danger Zone (or directly in Postgres — a `provision-teams.sh --cleanup` mode is on the roadmap as Phase 21).
2. **GitHub org:** remove the user from org → **People** → **Remove from org** (via UI or `gh api DELETE /orgs/byu-ml-capstone/members/<username>`).
3. **GitHub Teams:** deleting the org member auto-removes them from all Teams. Team itself can be deleted via `gh api DELETE /orgs/byu-ml-capstone/teams/<slug>` if unused.
4. **Repos:** student org repos survive unless deliberately deleted. Consider transferring valuable repos back to the student's personal account before removing them from the org (they lose access on removal). Or leave repos public + archive them.

---

## Mid-semester "reset a group" (they broke their setup badly)

If a team's Applications get into a weird state:

1. **Delete their Applications** (via Coolify UI → Application → Danger Zone → Delete).
2. **Re-run through student-guide Step 5-6** — they recreate the Applications from scratch, get new Deploy Webhook URLs, update their repo secrets.

Their code + GitHub repos are untouched — only Coolify state is reset. The Coolify Team + `ml-capstone` server + destination all survive because those live in the DB independently of Applications.

## Repo naming convention in the class org

30 students + one org = namespace collisions if everyone names their repo `hello-world-app`. The convention documented in [`student-guide.md`](student-guide.md) Step 4 is:

```
<team-slug>-<app>
```

Examples:
- Individual sandbox phase: `alice-sandbox-hello`, `alice-sandbox-sentiment`
- Group phase: `group-1-sentiment`, `group-3-recommender`

`<team-slug>` should be a lowercased, dash-separated version of the student's Coolify team name (e.g., "Alice's Sandbox" → `alice-sandbox`). This aligns:
- Repo path: `byu-ml-capstone/alice-sandbox-hello`
- Coolify team: "Alice's Sandbox"
- Deploy domain: `alice-sandbox.ml-capstone.cs.byu.edu` (production) or `alice-sandbox-staging.ml-capstone.cs.byu.edu` (staging)

If you'd rather use GitHub username as the prefix instead (e.g., `qsnell-hello`), that also works — just be consistent and document your choice in the syllabus/intro handout.

## Grant a GitHub Team access to a group's repo

After a group creates their group repo (e.g., `byu-ml-capstone/group-1-sentiment`), grant the matching GitHub Team Write access so every group member can push:

```bash
gh api -X PUT /orgs/byu-ml-capstone/teams/group-1/repos/byu-ml-capstone/group-1-sentiment -f permission=push
```

Team slugs are derived from the Coolify team name (lowercased + dash-separated). "Group 1" → `group-1`, "Alice's Sandbox" → `alice-s-sandbox`, etc. See slugify function in `scripts/provision-gh-teams.sh` for the exact rule.

This step could be automated in a future script iteration (e.g., a `grant-team-to-repos.sh` that scans repos matching `<team-slug>-*` and grants team access), but manually granting one team → one repo is trivial via `gh` CLI and only happens once per group.
