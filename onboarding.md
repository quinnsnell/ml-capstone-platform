# Admin checklist — onboarding a student group

This is the step-by-step procedure to onboard one student group at the start of a semester (or mid-semester if a new group forms). Follow top to bottom.

Naming convention: student groups are `Group1`, `Group2`, ..., `Group9`. Adjust in your head if you're using different names.

---

## Prerequisites — do these once per semester, not per group

Before you onboard anyone, verify:

- The cluster is healthy — run `./scripts/smoke-test-cluster.sh` (14/14 expected)
- `ml-capstone.cs.byu.edu` and `ml-capstone-admin.cs.byu.edu` resolve internally
- CS IT has added the wildcard `*.ml-capstone.cs.byu.edu` → rigel (delivered 2026-08-11 — all subdomains under `ml-capstone.cs.byu.edu` resolve internally to the cluster)
- The `byu-ml-capstone-coolify` GitHub App exists and is installed on the class GitHub org (if any)
- Coolify's OAuth is enabled with GitHub (Settings → OAuth)

If any of the above are missing, see [`admin-guide.md`](admin-guide.md) and [`coolify-runbook.md`](coolify-runbook.md) first.

---

## Per-group onboarding — do this once per group

### 1. Create the group's GitHub repo

Options (pick one, be consistent across all groups):

- **Class GitHub org (recommended):** create `<class-org>/group1` empty repo. Install the `byu-ml-capstone-coolify` GitHub App on it (or on the whole org — one-time).
- **Student's personal account:** one student owns the group's repo. They install the `byu-ml-capstone-coolify` GitHub App on their repo when they onboard.

Either way: the repo starts empty. Students seed it (typically by forking `github.com/byu-ml-capstone/sentiment-test-app` as a starting template, then customizing).

### 2. DNS — nothing to do

The wildcard `*.ml-capstone.cs.byu.edu` → rigel is live (2026-08-11). Both `Group1.ml-capstone.cs.byu.edu` and `Group1-staging.ml-capstone.cs.byu.edu` resolve automatically to rigel's internal IP for VPN clients. No per-group DNS work needed.

Verify: `nslookup Group1.ml-capstone.cs.byu.edu` should return `10.55.10.70` (rigel).

### 3. Create the Coolify Team for the group

Sign in to Coolify at `https://ml-capstone-admin.cs.byu.edu`.

- Left sidebar → **Teams** → **+ New Team**
- Name: `Group1`
- Description: `<class name>, term, group members`
- Set resource quotas: **Memory 4 GB, CPU 2 cores, Disk 20 GB** (adjust for the class)

### 4. Invite the group's students

Team → **Members** → **Invite**. Enter each student's GitHub email address.

Students will receive an email invite. They click, sign in with GitHub, land in the Coolify Team.

Alternative: give the group a signup link, they self-serve.

### 5. Provision two Coolify Applications for the group (staging + prod)

Inside the group's Team, create:

**Application 1 — staging**
- Name: `group1-staging`
- Source: `byu-ml-capstone-coolify` GitHub App
- Repository: `<class-org>/group1` (or `<student-owner>/group1`)
- Branch: `staging`
- Build pack: Dockerfile
- Ports mapping: `<host-port>:<container-port>` — pick a unique host port (e.g., `8110` for Group1 staging, `8111` for Group1 prod)
- Environment Variables:
  - `LITELLM_URL=http://ml-capstone.cs.byu.edu:4000/v1`
  - `LITELLM_API_KEY=sk-noauth`
  - `MODEL=classroom-chat`
  - `CUDA_VISIBLE_DEVICES=<N>` where `N = (group_number - 1) % 4` (spreads groups across GPUs)
- Domain: `Group1-staging.ml-capstone.cs.byu.edu`
- Auto Deploy: **OFF** (deploys come from GitHub Actions)
- Enable GPU (Configuration → Advanced → GPU section)

**Application 2 — production** — same as staging, but:
- Name: `group1`
- Branch: `main`
- Domain: `Group1.ml-capstone.cs.byu.edu`
- Different host port if you're using explicit port mappings

### 6. Copy each Application's Deploy Webhook URL

For each of the two Applications, go to **Webhooks** tab and copy the **Deploy Webhook URL**. It looks like:

```
https://ml-capstone-admin.cs.byu.edu/api/v1/deploy?uuid=<app-uuid>&force=false
```

You'll send both URLs to the group.

### 7. Generate a Coolify API token for the group

Coolify → **Keys & Tokens** → **API Tokens** → **+ New**
- Name: `group1-github-actions`
- Scope: minimum needed to trigger deploys (or full access — tighten later)
- Copy the token

You'll send this to the group along with the webhook URLs.

### 8. Hand off to the group

Send the group's members:

- **GitHub repo URL** (from step 1)
- **Their app URLs:**
  - Staging: `http://Group1-staging.ml-capstone.cs.byu.edu`
  - Production: `http://Group1.ml-capstone.cs.byu.edu`
- **GitHub Actions secrets** they need to set on their repo (Settings → Secrets and variables → Actions):
  - `COOLIFY_DEPLOY_WEBHOOK_STAGING` = (staging webhook URL from step 6)
  - `COOLIFY_DEPLOY_WEBHOOK_PROD` = (prod webhook URL from step 6)
  - `COOLIFY_API_TOKEN` = (token from step 7)
- Point them at [`student-guide.md`](student-guide.md) for the rest.

---

## Off-boarding a group (end of semester or drop)

1. **Coolify:** delete the two Applications. Delete the Team (removes members).
2. **DNS:** if per-group records were added, ask CS IT to remove them. If wildcard, no action.
3. **GitHub App:** if the App was installed only on this group's repo, uninstall from that repo. If org-wide, no per-group action.
4. **Rotate:** the group's `COOLIFY_API_TOKEN` will be orphaned when the App is deleted; no rotation needed. If the group's repo continues to exist and might use the token elsewhere, revoke it in Coolify.

---

## Mid-semester "reset a group" (they broke their setup badly)

If a group's Applications get into a weird state:

1. Delete both their Applications (staging + prod)
2. Recreate per step 5 above (same names, same env vars, same domain)
3. Re-copy their Deploy Webhook URLs (they'll be different) and API token
4. Have them update their GitHub repo secrets

Their code and git history are untouched — only Coolify state is reset.

---

## Bulk onboarding

Use [`scripts/provision-teams.sh`](scripts/provision-teams.sh). It reads a roster CSV and idempotently creates Coolify teams, users, and their per-team `ml-capstone` server row via direct Postgres writes (Coolify's REST API doesn't cover team or user creation as of 4.2).

```bash
# On rigel, as a user in the docker group (or with sudo):
./scripts/provision-teams.sh                          # dry-run against newest roster-*.csv
./scripts/provision-teams.sh --roster path.csv        # explicit roster
./scripts/provision-teams.sh --check-schema           # dump DB layout before trusting the SQL
./scripts/provision-teams.sh --roster path.csv --apply  # execute
```

CSV columns: `team_name,email,name,github_username`. One row per (team, user) pair — multi-row-per-user is fine (a user in multiple teams gets multiple rows). See `roster-example.csv`.

After provisioning: students sign in via GitHub OAuth (email on their GitHub account must match their roster row) and self-create their Projects, Environments, and Applications per [`student-guide.md`](student-guide.md) → Part B → Setup section.

Applications are still created by students (Coolify's API supports app creation but classroom pedagogy is better if students walk the UI themselves the first time).

## Invite students to the class GitHub org

**Runs from your laptop, not rigel** (needs `gh` CLI authenticated as an Owner of `byu-ml-capstone`). Reads the same roster CSV:

```bash
./scripts/invite-to-org.sh                          # dry-run against newest roster-*.csv
./scripts/invite-to-org.sh --roster path.csv --apply
./scripts/invite-to-org.sh --org other-name         # different org name
```

Idempotent — users who are already members or have a pending invite are skipped. Every roster row needs a valid `github_username` for this to work.

**Order of operations at term start:**
1. `./scripts/invite-to-org.sh --apply` (send org invitations from laptop)
2. `sudo ./scripts/provision-teams.sh --apply` (create Coolify teams+servers on rigel)
3. Students accept the org invite + sign in to Coolify → land in their pre-provisioned team → create their repo from the `hello-world-app` template inside the org.

Steps 1 and 2 can happen in any order — they don't depend on each other. But students can't complete their setup until BOTH have run.
