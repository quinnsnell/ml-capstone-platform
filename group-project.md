# Moving to Your Group Project

You have been deploying to your **personal sandbox** all term. Your group now
has its own Coolify team, its own server, and its own GitHub team — and you are
going to stand up one shared project in it.

You are not starting from scratch. Pick one member's existing app, copy it into
a group repo, point Terraform at the group team, and deploy. From there you
build the real project together.

Budget about 30 minutes for the member doing the setup, and read
[the gotchas](#four-things-that-will-bite-you) first — three of them have
already cost people in this class an afternoon.

---

## Before you start

**Decide two things as a group:**

1. **Whose project do you start from?** Usually whoever is furthest along, or
   whose app is closest to what the group wants to build. It does not have to
   be anyone's "best" work — you will be rewriting most of it.
2. **Who does the setup?** One person. They need a laptop with `git`,
   `terraform`, and the CS VPN. Everyone else waits ten minutes, then clones.

**Your group already has**, provisioned for you:

| | |
|---|---|
| Coolify team | the short name for your project — `amby-slm`, `fs-tree`, `gsl-forecast`, and so on |
| Coolify server | `ml-capstone`, inside that team |
| GitHub team | same name, at `github.com/orgs/byu-ml-capstone/teams/<your-team>` |

You do **not** have a group repo, a group Coolify project, or group
Applications yet. That is what this page is for.

---

## 1. Copy the starting project into a group repo

Pick a repo name for the group. Same rules as the first lab — lowercase, no
spaces, descriptive — and it becomes your deploy hostname, so keep it short.
Something like `amby-slm-app` or `gsl-forecast`.

This copies **all branches and all history** from the source repo. That matters:
you need `main` *and* `staging`, and you want the commit history so the original
author's work is not thrown away.

```bash
# 1. Make the empty group repo
gh repo create byu-ml-capstone/<group-repo> --private

# 2. Mirror the source repo into it
git clone --bare https://github.com/byu-ml-capstone/<source-repo>.git
cd <source-repo>.git
git push --mirror https://github.com/byu-ml-capstone/<group-repo>.git
cd ..
rm -rf <source-repo>.git

# 3. Clone the group repo normally, and work here from now on
git clone https://github.com/byu-ml-capstone/<group-repo>.git
cd <group-repo>
git branch -a          # you should see both main and staging
```

> **No `gh` CLI?** Create the empty repo at
> [github.com/organizations/byu-ml-capstone/repositories/new](https://github.com/organizations/byu-ml-capstone/repositories/new),
> then run steps 2–3. Do **not** use "Use this template" on a classmate's repo —
> it drops the history, and unless you tick *Include all branches* it drops
> `staging` too.

**Do not fork.** A fork inside the same org stays tied to the original, and
pull requests default to targeting the *source* repo rather than yours.

## 2. Give your group access to the repo

Your GitHub team already exists with everyone in it. Grant it write access:

**Repo → Settings → Collaborators and teams → Add teams →** pick your group
team → role **Write** → Add.

Or in one command:

```bash
gh api -X PUT \
  /orgs/byu-ml-capstone/teams/<your-team>/repos/byu-ml-capstone/<group-repo> \
  -f permission=push
```

Everyone in the group can now clone and push. Have them do it now, so you find
out immediately if someone is missing from the team.

## 3. Make a Coolify token for the GROUP team

**Your existing token will not work.** A Coolify API token is permanently bound
to whichever team was active when you created it, and yours is bound to your
personal sandbox. Using it here creates the project in your sandbox — which
looks like it worked, right up until nobody else can see it.

1. Open [ml-capstone-admin.cs.byu.edu](https://ml-capstone-admin.cs.byu.edu) on
   the CS VPN
2. **Switch teams first.** The team switcher is the breadcrumb at the top of the
   main panel. Select your **group** team. Confirm it is showing before
   continuing — this is the step people skip
3. Coolify wordmark → **Keys & Tokens → API Tokens → + New Token**
4. Name it after the group, permission **`root`**, then **Create token**
5. Copy it immediately. It is shown once

> **Why `root`:** it means root *of this team*, not of the server. Terraform
> needs both write and deploy, and Coolify's UI collapses the selection to
> `deploy` alone if you tick both — so `root` is the only workable choice. If
> everything except `read` is greyed out, you are looking at a team you are only
> a member of; switch teams.

## 4. Get the group's server UUID

Every team has its own server record, all named `ml-capstone`, each with a
different UUID. Your personal one will not work here.

```bash
curl -H "Authorization: Bearer <your-new-group-token>" \
  https://ml-capstone-admin.cs.byu.edu/api/v1/servers
```

Exactly one server comes back. Copy its `uuid`.

## 5. Fill in `terraform.tfvars`

In your freshly cloned group repo:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Every value changes from the personal project. All four:

| Variable | What goes in it |
|---|---|
| `repo_name` | your **group** repo name — just the name, no `byu-ml-capstone/` prefix |
| `coolify_api_token` | the **group** token from step 3 |
| `coolify_server_uuid` | the UUID from step 4 |
| `github_token` | a GitHub PAT with `repo` scope — `gh auth token`, or [github.com/settings/tokens](https://github.com/settings/tokens) |

> **Edit `terraform.tfvars`, not `terraform.tfvars.example`.** The `.example`
> file is tracked by git and must keep its `REPLACE_ME` placeholders. Someone in
> this class lost an hour to a `401 Bad Credentials` caused by editing the wrong
> file. `terraform.tfvars` is gitignored, which is why your real tokens belong
> only there.

## 6. Apply

```bash
terraform init
terraform plan        # read this before applying
terraform apply       # type: yes
```

`plan` should end with **`Plan: 7 to add, 0 to change, 0 to destroy`**.

**If it says anything about destroying,** stop. You are running inside a
directory that still has state from the personal project. See
[the gotchas](#four-things-that-will-bite-you).

This creates the Coolify project, both environments, both Applications, and the
three GitHub Actions secrets on the group repo.

## 7. Set the two domains, then redeploy

Terraform cannot do this part. For **each** of the two Applications:

1. **Access** → gear icon on *"N configured domains"* → **+ Add**
2. **Service:** your public service — `frontend` on the current template, or
   whatever your app calls it. Never `backend` or `db`
3. **Protocol:** `https`
4. **Domain:** `<group-repo>-staging.ml-capstone.cs.byu.edu`, and
   `<group-repo>.ml-capstone.cs.byu.edu` for production — **no** `http://`, the
   protocol is the dropdown above
5. **Port** and **Path:** leave both empty. Traefik works it out
6. **Save**, then hit **Redeploy**

Delete the auto-generated `sslip.io` placeholder and any `www.` row while you
are there. `www.` cannot be made to work — the wildcard certificate covers one
level of subdomain only.

**The redeploy is not optional.** Traefik bakes routing labels into the
container at start, so a domain added afterwards leaves your URL returning
`404` until a new container comes up.

## 8. Deploy and check

```bash
git checkout staging
# make any small change, e.g. bump APP_VERSION
git add -A
git commit -m "group project: first deploy"
git push
```

Watch Actions, then Coolify's Deployments tab. When it lands:

```bash
./smoke-test.sh https://<group-repo>-staging.ml-capstone.cs.byu.edu
```

Then promote to production with a pull request from `staging` into `main`, the
same way you did in the first lab.

Once that is green, **start changing things.** The point was never to deploy
someone's old app — it was to get a working pipeline under the group so the
first real feature has somewhere to land.

---

## Four things that will bite you

**1. Stale Terraform state.** If you run `terraform apply` in your *personal*
project directory after editing the tfvars, Terraform still holds state for the
personal project and will try to move it rather than create something new. Work
in a **fresh clone of the group repo** — its `terraform/` has no
`terraform.tfstate`, which is exactly what you want. Never copy a `.tfstate`
file between projects.

**2. The wrong token.** Covered in step 3, and worth repeating because the
failure is silent: a sandbox-scoped token creates a project your group cannot
see. If `terraform apply` succeeds but the project does not appear under the
group team, this is why. Delete the project, make a group-scoped token, apply
again.

**3. Both branches.** Your group repo needs `main` *and* `staging`. The mirror
push in step 1 brings both. If `git branch -a` shows only `main`, fix it before
deploying:

```bash
git checkout -B staging main
git push -u origin staging
```

**4. The service name in the domain.** If you rename the service in
`docker-compose.yaml`, the domain in Coolify still points at the old name and
Traefik has no route — a `404` on a deploy that otherwise succeeded. Re-attach
the domain to the new service name, in **both** environments, then redeploy.

## What about my personal project?

Leave it. Your sandbox team, repo and Applications stay exactly as they are —
you are a member of two Coolify teams now, and the switcher moves between them.
Nothing in the group setup touches your sandbox.

Do not delete your old Coolify project just to tidy up. It costs nothing to
leave running, and if the group setup goes sideways it is useful to still have
something that works.

## Where to look when something breaks

- [Troubleshooting](troubleshooting.md) — symptom-first, covers every failure
  this class has actually hit
- [Lab: your first deploy](lab-first-deploy.md) — the long-form version of
  steps 3–8, with more explanation
- [Migrating your project](migrating-your-project.md) — the requirements your
  compose file has to satisfy, in a form you can hand to a coding agent

If your URL returns `404` right after setup, you almost certainly skipped the
redeploy in step 7.
