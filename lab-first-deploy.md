# Lab — Your First Deploy

Take a repo from your laptop to a live URL, using Terraform to create the
infrastructure and GitHub Actions to deploy it.

Budget about 90 minutes. Work in order — each step depends on the one before.

> **The condensed version of Part B.** [`student-guide.md`](student-guide.md) has
> the long explanations, every screenshot-level detail, and the Coolify-UI
> alternative if Terraform gives you trouble. Use this page to move; use the
> guide when you want to know *why*.

---

## Before you start

You should already have, from the pre-lab email:

- [ ] Accepted the **byu-ml-capstone** GitHub organization invitation
- [ ] Created your repo from the `hello-world-app` template, owned by **byu-ml-capstone**, named `yourname-appname`, with **Include all branches** checked
- [ ] **Docker Engine 25+** — check with `docker version`
- [ ] Connected to the **CS VPN** (`cs-vpn.byu.edu` portal, *not* campus `vpn.byu.edu`)

Missing any of those? Fix it first — every later step depends on them.

---

## 1. Sign in to Coolify and look around

Open <https://ml-capstone-admin.cs.byu.edu> and **Sign in with GitHub**.

**Change nothing yet.** You are here to confirm your account works and to see
what empty looks like, so the difference after Terraform runs is obvious.

Check three things:

| Where | What you should see |
|---|---|
| Team switcher (top of the main panel) | your own team, e.g. *Alice Smith's Sandbox* |
| Left sidebar → **Servers** | one server, `ml-capstone`, green "reachable" |
| Left sidebar → **Projects** | empty |

**"Registration is disabled. Please contact the administrator"** means the email
on your GitHub account doesn't match your roster row. Tell the instructor which
email to use — don't create a second account.

---

## 2. Clone your repo and switch to staging

Clone **your** repo, not the template:

```bash
git clone https://github.com/byu-ml-capstone/<your-repo>.git
cd <your-repo>
git branch -a          # you should see main and staging
git checkout staging
```

Everything in this lab happens on `staging`. You will promote to `main` at the
end — that is the point of having two branches.

If `git branch -a` shows only `main`, you missed **Include all branches** when
creating the repo. Easiest fix is to delete the repo and redo the template step.

---

## 3. Start the local build now

The first build pulls images and installs dependencies and takes a few minutes.
Start it, then keep reading — steps 4 and 5 happen in the browser while this runs.

```bash
export SERVICE_FQDN_HELLO=http://localhost:8000
docker compose up -d --build
```

When it finishes, check all three services and run the smoke test:

```bash
docker compose ps        # hello, time, db — all "healthy"
./smoke-test.sh
```

`smoke-test.sh` builds, waits for `/health`, then exercises every endpoint. Green
here means your code is sound; anything that fails now will also fail deployed,
just slower.

Poke at it by hand too:

```bash
curl -s localhost:8000/
curl -s localhost:8000/health
curl -s "localhost:8000/?lang=es"
curl -s -X POST localhost:8000/notes -H 'Content-Type: application/json' -d '{"body":"hello"}'
curl -s localhost:8000/notes
```

Leave it running or `docker compose down` — either is fine from here on.

---

## 4. Create a Coolify API token

Terraform needs to authenticate as you.

**Switch to your own team first.** The token is scoped to whichever team is
active when you create it, and that decides where your Applications get created.

Then: click the **Coolify** wordmark (top-left) → **Keys & Tokens → API Tokens →
+ New Token**

- Description: `terraform`
- Permissions: tick **`write`** and **`deploy`**
- Expires: 1 year
- Create — then **copy it immediately**. Coolify shows it exactly once.

> You will not see a `root` permission option. That exists only in the
> instructor's Root Team. `write` + `deploy` is what this lab needs.

---

## 5. Find your server UUID

Coolify gives **every team its own server record**. They are all named
`ml-capstone` and all point at the same machine, but each has a different UUID —
so there is no value that works for everyone, and you cannot copy a neighbour's.

```bash
curl -H "Authorization: Bearer <your-token>" \
  https://ml-capstone-admin.cs.byu.edu/api/v1/servers
```

Exactly one server comes back. Copy its `uuid`.

---

## 6. Fill in your Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and set four values:

| Variable | Value |
|---|---|
| `coolify_token` | the token from step 4 |
| `github_token` | run `gh auth token`, or create a classic PAT with `repo` scope |
| `repo_name` | just the repo name — `alice-hello`, **not** `byu-ml-capstone/alice-hello` |
| `coolify_server_uuid` | the UUID from step 5 |

`terraform.tfvars` holds two live credentials. It is already in `.gitignore`.
**Never commit it.**

---

## 7. init, plan, apply

```bash
terraform init        # downloads the providers, verifies them against the lock file
terraform plan        # READ THIS before continuing
terraform apply       # type: yes
```

`plan` should end with:

```
Plan: 7 to add, 0 to change, 0 to destroy.
```

**Read the plan.** Building that habit is most of the reason we use Terraform at
all — it tells you exactly what is about to happen while it is still free to
change your mind. Find the two `coolify_application` resources and notice one
tracks `staging` and the other `main`.

`apply` prints your two URLs and the Application UUIDs when it finishes.

**If `plan` fails**, the message usually names the problem:

| Error mentions | Fix |
|---|---|
| `coolify_server_uuid is required` | step 5 — you left it blank |
| `401` / `Unauthenticated` | token wrong, or pasted with a trailing space |
| `404` on the application | wrong server UUID — you used another team's |
| `repo_name should be just the repo name` | you included the `byu-ml-capstone/` prefix |

---

## 8. See what Terraform created

**In Coolify** — Projects → **your repo name** (not `hello-world-app`; the
project is named after your repo). Inside it:

- environments `production` and `staging`
- one Application in each, tracking `main` and `staging` respectively
- Auto Deploy already **off** — GitHub Actions drives deploys, not Coolify

**In GitHub** — your repo → **Settings → Secrets and variables → Actions**.
Three secrets, created by Terraform:

```
COOLIFY_API_TOKEN
COOLIFY_DEPLOY_WEBHOOK_STAGING
COOLIFY_DEPLOY_WEBHOOK_PROD
```

Those are what let GitHub Actions tell Coolify to deploy. `.github/workflows/ci.yml`
already references them by exactly these names.

---

## 9. Set your two domains — the one manual step

Terraform cannot do this. Coolify's API will not accept per-service domains on a
Docker Compose application, so it stays a UI step and is documented as one.

For **each** of your two Applications:

**Access → the gear icon on "1 configured domain"** (or the **Domains** tab) →
under service **`hello`**, set the domain → **Save**

| Application | Domain |
|---|---|
| staging | `http://<your-repo>-staging.ml-capstone.cs.byu.edu` |
| production | `http://<your-repo>.ml-capstone.cs.byu.edu` |

Delete the auto-generated `<longhash>.sslip.io` placeholder and the `www.`
variant if Coolify added one. Do **not** click "Generate Domain".

> **`http://`, not `https://`.** The CS wildcard certificate covers one level
> under `cs.byu.edu` and these names are two levels deep, so student apps are
> routed on HTTP only. An `https://` request returns `503 no available server`,
> not a certificate warning.

> **Do this before your first deploy.** Traefik bakes routing labels into a
> container when it starts. Set the domain afterwards and your URL returns
> `404 page not found` until you hit **Redeploy**.

---

## 10. Make a change and push to staging

Bump the version so you can see your change arrive:

```bash
# in hello/greetings.py
APP_VERSION = "0.1.2"
```

```bash
git add hello/greetings.py
git commit -m "bump version to 0.1.2"
git push origin staging
```

**Now watch it, in this order:**

1. **GitHub → Actions tab.** The `test` job runs first. When it passes,
   `deploy-staging` runs and `deploy-prod` is skipped — the branch decides.
2. **Coolify → your staging Application → Deployments.** Coolify builds a new
   image, starts containers, polls `/health`, then swaps traffic.
3. **Your staging URL:**

```bash
curl -s http://<your-repo>-staging.ml-capstone.cs.byu.edu/health
# {"ok":true,"version":"0.1.2"}
```

Check production too — still on the old version. **That is the point.** Nothing
reaches production until you promote it.

> Editing only `*.md` files will not trigger CI — the workflow ignores them on
> purpose. Change code.

---

## 11. Promote to production

```bash
gh pr create --base main --head staging --title "Promote 0.1.2 to production"
```

Or open the PR in the GitHub UI. Watch the checks run on the PR — `test` passes,
both deploy jobs skip, because a PR is not a push to a deploy branch.

Merge it. Then watch Actions again: `test` passes, `deploy-prod` runs,
`deploy-staging` skips. When it finishes:

```bash
curl -s http://<your-repo>.ml-capstone.cs.byu.edu/health
# {"ok":true,"version":"0.1.2"}
```

Both environments now match — because you promoted, not because anything was
automatic.

---

## When something goes wrong

| Symptom | Most likely cause |
|---|---|
| Coolify: "Registration is disabled" | GitHub email doesn't match your roster row |
| `terraform plan` 401 | token wrong or has trailing whitespace |
| `terraform plan` 404 on application | wrong server UUID — you used another team's |
| Your URL: `404 page not found` | nothing deployed yet, or domain set after deploy — hit **Redeploy** |
| Your URL: `503 no available server` | you used `https://` — student apps are HTTP only |
| Your URL hangs / won't resolve | not on the CS VPN, or on campus `vpn.byu.edu` instead of `cs-vpn.byu.edu` |
| Pushed, but no Actions run | you only changed markdown |
| Actions red at `test` | your code is broken — nothing deployed, old version still live |
| Deploy ran but version unchanged | health check failed; Coolify kept the old container |

Fuller answers in [`troubleshooting.md`](troubleshooting.md).

---

## What you just built

A push to `staging` runs your tests on a clean machine, and only if they pass
does it tell Coolify to build a new image, start it, health-check it, and swap
traffic — on infrastructure you described in a file rather than clicked into
existence. A pull request moves the same code to production under the same rules.

That is the same shape as a professional deployment pipeline. The provider would
change at a different company; almost nothing else would.
