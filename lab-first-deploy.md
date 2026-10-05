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
- [ ] **Docker Engine 25+** — check with `docker version`
- [ ] Connected to the **CS VPN** (`cs-vpn.byu.edu` portal, *not* campus `vpn.byu.edu`)

Missing any of those? Fix it first — every later step depends on them. In
particular, you cannot create a repository inside the organization until you have
accepted the invitation, so step 1 will fail.

---

## 1. Create your repository from the template

Everyone starts from the same template repo and makes their own copy of it.

If you already did this from the pre-lab email, just run the verification at the
end of this step and move on.

Go to the **byu-ml-capstone** organization on GitHub, open **hello-world-app**,
and click the green **Use this template** → **Create a new repository**.

Four things on that screen:

**Owner — change it to `byu-ml-capstone`.** It defaults to your personal account,
which is wrong. A repo in the wrong place has no Coolify source and cannot deploy,
and you will not find out until several steps later.

**Repository name — be deliberate.** This name is not throwaway:

- it becomes your app's web address — `alice-hello` → `alice-hello.ml-capstone.cs.byu.edu`
- it becomes your Coolify project name
- it sits in a shared class organization that your instructor, your classmates, and later your group will all browse

Use `<yourname>-<appname>`, lowercase, hyphens between words:

| Good | Why |
|---|---|
| `asmith-hello` | identifies you, says what it is |
| `jdoe-sentiment` | still obvious in a list of thirty |
| `mchen-recommender` | reads fine as a URL |

| Avoid | Why |
|---|---|
| `test`, `myapp`, `project1` | meaningless in a list of thirty |
| `Alice_Hello App` | spaces and capitals make an ugly URL |
| in-jokes and handles | this is coursework in a shared org, and it ends up in a URL you will share |

Treat it the way you would a repo at work, because that is the habit being built.

**"Include all branches" — check this box.** You need both `main` and `staging`.

**Public or private** — either is fine.

Then click **Create repository from template**.

**Verify before moving on.** On your new repo's page, click the branch dropdown
above the file list. You should see **both** `main` and `staging`. If you only see
`main`, you missed the checkbox — delete the repo and redo this step now rather
than working around it later.

---

## 2. Sign in to Coolify and look around

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

## 3. Clone your repo and switch to staging

Clone **your** repo, not the template:

```bash
git clone https://github.com/byu-ml-capstone/<your-repo>.git
cd <your-repo>
git branch -a          # you should see main and staging
git checkout staging
```

Everything in this lab happens on `staging`. You will promote to `main` at the
end — that is the point of having two branches.

If `git branch -a` shows only `main`, go back to step 1 — the **Include all
branches** box was missed.

### One command before you start working

```bash
git checkout -B staging main
git push --force origin staging
```

**Do this now, before you change anything.** When GitHub copies a template it
gives each branch its own separate first commit, so `main` and `staging` start
life with no shared history. Git will refuse to open a pull request between them
later:

```
pull request create failed: The staging branch has no history in common with main
```

At this moment the two branches hold identical files, so rebuilding `staging` on
top of `main` costs you nothing and loses nothing. Do it after you have real work
on `staging` and it costs you that work.

---

## 4. Start the local build now

The first build pulls images and installs dependencies and takes a few minutes.
Start it, then keep reading — steps 5 and 6 happen in the browser while this runs.

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

## 5. Create a Coolify API token

Terraform needs to authenticate as you.

**Switch to your own team first.** The token is scoped to whichever team is
active when you create it, and that decides where your Applications get created.

Then: click the **Coolify** wordmark (top-left) → **Keys & Tokens → API Tokens →
+ New Token**

- Description: `terraform`
- Permissions: tick **`root`**
- Expires: 1 year
- Create — then **copy it immediately**. Coolify shows it exactly once.

> **Why `root` and not `write` + `deploy`?** Coolify's permissions are mutually
> exclusive in a way the UI does not explain: clicking `deploy` clears everything
> else you had selected, so you cannot hold `write` and `deploy` together.
> Terraform needs both — `write` to create your applications, `deploy` to trigger
> deploys — and `root` is the single option that covers them.
>
> `root` here means root **of your own team**, not of the whole Coolify instance.
> Your token can only see and change your team's resources. If `root` is greyed
> out, you are looking at a team you are only a member of — switch to your own.

---

## 6. Find your server UUID

Coolify gives **every team its own server record**. They are all named
`ml-capstone` and all point at the same machine, but each has a different UUID —
so there is no value that works for everyone, and you cannot copy a neighbour's.

```bash
curl -H "Authorization: Bearer <your-token>" \
  https://ml-capstone-admin.cs.byu.edu/api/v1/servers
```

Exactly one server comes back. Copy its `uuid`.

---

## 7. Fill in your Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and set four values:

| Variable | Value |
|---|---|
| `coolify_token` | the token from step 5 |
| `github_token` | run `gh auth token`, or create a classic PAT with `repo` scope |
| `repo_name` | just the repo name — `alice-hello`, **not** `byu-ml-capstone/alice-hello` |
| `coolify_server_uuid` | the UUID from step 6 |

### Getting your GitHub token

Terraform needs it for two things: reading your repository, and writing the three
GitHub Actions secrets onto it.

**If you have the GitHub CLI**, this is the whole job:

```bash
gh auth token
```

Copy the output — about 40 characters, starting `gho_` or `ghp_`.

**From the GitHub website**, if you don't have `gh`:

1. Sign in to github.com and click your **avatar** (top right) → **Settings**
2. Scroll to the very bottom of the left sidebar → **Developer settings**
3. **Personal access tokens** → **Tokens (classic)**
4. **Generate new token** → **Generate new token (classic)**
5. **Note:** `terraform-lab`
6. **Expiration:** pick something that covers the course. If it lapses you can
   generate another — avoid "No expiration"
7. **Scopes:** tick the top-level **`repo`** box. That selects its sub-boxes and
   is all you need
8. Scroll to the bottom → **Generate token**
9. **Copy it immediately.** GitHub shows it exactly once. It starts `ghp_`

> Using a **fine-grained** token instead? Give it access to your repo, then under
> **Repository permissions** set **Secrets → Read and write** (Metadata → Read is
> added for you). Classic tokens are simpler for this lab.

### Then guard the file

`terraform.tfvars` now holds two live credentials — one that can change your
Coolify team, one that can act on your GitHub repositories. It is already in
`.gitignore`. **Never commit it**, and don't paste it into Slack or an issue.

---

## 8. init, plan, apply

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
| `coolify_server_uuid is required` | step 6 — you left it blank |
| `401` / `Unauthenticated` | token wrong, or pasted with a trailing space |
| `404` on the application | wrong server UUID — you used another team's |
| `repo_name should be just the repo name` | you included the `byu-ml-capstone/` prefix |

---

## 9. See what Terraform created

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

## 10. Set your two domains — the one manual step

Terraform cannot do this. Coolify's API will not accept per-service domains on a
Docker Compose application, so it stays a UI step and is documented as one.

**Do this before your first deploy.** Traefik bakes routing labels into a
container when it starts, so a domain set afterwards leaves your URL returning
`404 page not found` until you hit **Redeploy**.

### Click by click, for staging

1. Left sidebar → **Projects**
2. Click **your project** — the name you chose in step 1.
   *Do not click the gear icon on that row.*
3. Click **staging**.
   *Again, not the gear icon.*
4. Click your one resource. It is named something like
   `<your-repo>:staging-<random text>` — the random part is normal.
5. In the **Access** section, click the **gear icon** next to *"1 configured domain"*
6. Click **+ Add**
7. **Service:** `hello` — this dropdown lists your containers, and `hello` is the
   only one users should reach
8. **Protocol:** `http` — check it, do not assume
9. **Domain:** `<your-repo>-staging.ml-capstone.cs.byu.edu`
   — **without** the `http://`; the protocol is the separate dropdown above
10. **Port:** leave it empty. Traefik works out the routing.
11. **Path:** leave it empty too.
12. Click **Save**

### Then production

Same path, but click **production** at step 3, and the resource will be named
`<your-repo>:main-<random text>`. The domain is your repo name with no suffix:

`<your-repo>.ml-capstone.cs.byu.edu`

### While you are there

Delete the auto-generated `<longhash>.sslip.io` placeholder, and the `www.`
variant if Coolify added one. Do **not** click "Generate Domain".

> **`http://`, not `https://`.** The CS wildcard certificate covers one level
> under `cs.byu.edu` and these names are two levels deep, so student apps are
> routed on HTTP only. An `https://` request returns `503 no available server`,
> not a certificate warning — which looks like a broken deploy but isn't.

---

## 11. Make a change and push to staging

Bump the version so you can see your change arrive:

```bash
# in hello/greetings.py
APP_VERSION = "0.1.2"
```

```bash
git status                 # see exactly what you changed
git add -A                 # stage all of it
git commit -m "bump version to 0.1.2"
git push origin staging
```

`git add -A` stages everything — files you edited, files you deleted, and files
you created. `git status` first is the habit worth keeping: `-A` sweeps up new
files too, and `terraform.tfvars` is only kept out of your commits by a line in
`.gitignore`. Look before you stage.

**Now watch it, in this order:**

1. **GitHub → Actions tab.** The `test` job runs first. When it passes,
   `deploy-staging` runs and `deploy-prod` is skipped — the branch decides.
2. **Coolify → your staging Application → Deployments.** Coolify builds a new
   image, starts containers, polls `/health`, then swaps traffic.

> **Later, when you restructure this app:** every long-running service in
> `docker-compose.yaml` needs a `healthcheck:`. Coolify judges your application by
> its containers' health, and a service that reports *nothing* is treated as
> unhealthy rather than as fine — it will deploy cleanly and then be stopped hours
> later. The template has one on all three services; keep them when you rename or
> split things. See `troubleshooting.md` if an app dies after a successful deploy.
3. **Your staging URL:**

```bash
curl -s http://<your-repo>-staging.ml-capstone.cs.byu.edu/health
# {"ok":true,"version":"0.1.2"}
```

Now check production:

```bash
curl -s http://<your-repo>.ml-capstone.cs.byu.edu/health
# 404 page not found
```

**A 404 is the correct answer.** Nothing has ever been deployed to production —
the Application exists and has a domain, but no container has been built for it.
`deploy-prod` only runs on a push to `main`, and you have not made one.

That is the whole point of two environments: your change is live and testable on
staging, and production is untouched until you decide otherwise.

> Editing only `*.md` files will not trigger CI — the workflow ignores them on
> purpose. Change code.

---

## 12. Promote to production

### What a pull request is

A **pull request** — PR — proposes merging one branch into another. It is not a
git feature; it is a GitHub workflow built on top of one. It gives you three
things a direct merge does not:

- **a place to review** the diff before it lands
- **a place to run checks** — your tests run against the merged result
- **a record** of what changed, when, and who approved it

On a team, this is where someone else reads your code. Working alone, it is still
the checkpoint where you look at what you are about to put in front of users.

Note that `git` itself has no pull-request command — there is no `git pr`. Pull
requests live on GitHub, so you open one either in the browser or with GitHub's
CLI.

### Open it in the browser

Nothing to install, and you see the diff you are proposing:

1. Go to your repository on GitHub. Because you just pushed, a yellow banner
   offers **Compare & pull request** — click it.
   *No banner?* Click the **Pull requests** tab → **New pull request**.
2. Check the two branches at the top: **base: `main`** ← **compare: `staging`**.
   Base is where the code is going; compare is where it is coming from. Getting
   these backwards is the most common mistake.
3. Scroll down and read the diff. This is the part that matters — it is exactly
   what you are proposing to put in front of users.
4. **Title:** `Promote 0.1.2 to production`
5. **Description:** optional. *"Version bump validated on staging"* is plenty.
6. Click **Create pull request**.

### Or from the terminal, with the GitHub CLI

```bash
gh pr create --base main --head staging --title "Promote 0.1.2 to production"
```

It then prompts you:

- **Body** — press `e` to open an editor, or leave it empty and continue
- **What's next?** — choose **Submit**

> `gh` acts as whichever GitHub account it is logged in as, which is not
> necessarily the one you are using in the browser. Check with `gh auth status`,
> and switch with `gh auth switch` if it is the wrong one. If `gh` is
> authenticated as an account without access to the class organization, the
> command fails even though the browser would work fine.

Watch the checks run on the PR — `test` passes, and both deploy jobs skip, because
a pull request is not a push to a deploy branch. Nothing deploys from a PR.

> **`The staging branch has no history in common with main`** means you skipped
> the rebuild in step 3. Fix it now:
> ```bash
> git checkout -B staging main     # rebuild staging on main
> ```
> then re-apply your version bump, commit, and `git push --force origin staging`.

### Making review mandatory — how teams actually work

Right now nothing stops you merging your own pull request seconds after opening
it, or pushing straight to `main` and skipping the PR entirely. On a real team
neither is allowed. The mechanism is **branch protection**:

**Repository → Settings → Branches → Add branch protection rule** (newer repos:
**Settings → Rules → Rulesets → New ruleset**)

- **Branch name pattern:** `main`
- ☑ **Require a pull request before merging**
  - **Require approvals:** `1` — someone else must review it
- ☑ **Require status checks to pass before merging** → select **`test`**
- ☑ **Do not allow bypassing the above settings** — otherwise admins skip it

With that on, `main` can only change through a reviewed pull request whose tests
passed. The CI job you have been watching stops being advisory and becomes the
thing standing between a broken commit and production.

**Two reasons not to turn it on today:**

1. **You cannot approve your own pull request.** Working alone, requiring an
   approval locks you out of your own `main` branch.
2. **GitHub Free does not offer branch protection on private repositories.** If
   your repo is private — most are — the setting is unavailable until the repo is
   public or the organization is on a paid plan.

So treat this as something to read now and use later. **When you move to the group
project, turn it on.** That is the point at which "someone else reviews it" stops
being a formality and starts catching things — and it is the setting that makes
the pull request a gate rather than a ceremony.

Merge it. Then watch Actions again: `test` passes, `deploy-prod` runs,
`deploy-staging` skips. When it finishes:

```bash
curl -s http://<your-repo>.ml-capstone.cs.byu.edu/health
# {"ok":true,"version":"0.1.2"}
```

Both environments now match — because you promoted, not because anything was
automatic.

---

## 13. Moving on to your own project

`hello-world-app` is scaffolding. Your real project will have its own services —
commonly a `frontend`, a `backend`, and a `db`. You can throw away everything in
`hello/` and `time/` and replace it.

**What you can change freely:** service names, how many services there are, the
languages, the frameworks, the Dockerfiles, the dependencies, the endpoints. None
of that is special.

**What the platform requires** is a short list, and every item on it has already
bitten someone in this class.

### 1. The domain must point at the service that actually serves users

Rename `hello` to `frontend` and Coolify still has the domain attached to a service
called `hello` — which no longer exists. Traefik then has no route and your URL
returns `404 page not found`, even though the deploy succeeded and the containers
are healthy.

Re-attach it, **in both environments**: lab step 10, but pick `frontend` in the
Service dropdown.

### 2. `${SERVICE_FQDN_<SERVICE>}` must match that service's name

The variable name follows the service, uppercased, with `-` becoming `_`:

| Service | Variable |
|---|---|
| `hello` | `${SERVICE_FQDN_HELLO}` |
| `frontend` | `${SERVICE_FQDN_FRONTEND}` |
| `web-ui` | `${SERVICE_FQDN_WEB_UI}` |

Referencing it is what makes Coolify generate a route at all. Rename the service
and forget the variable, and nothing is ever published. Only the public service
needs one — `backend` and `db` must *not* have one, or Coolify will expose them.

### 3. Every long-running service needs a `healthcheck:`

This is the one that looks like the platform is broken. Coolify judges your
application by its containers' Docker health. A service with **no** health check
does not report "fine" — it reports nothing, and an application Coolify cannot
confirm is healthy gets marked unhealthy and stopped. Typically a couple of hours
after a deploy that said success, and the cleanup then removes the containers, so
the logs are gone before you look.

```yaml
frontend:
  build: ./frontend
  expose:
    - "80"
  environment:
    APP_URL: ${SERVICE_FQDN_FRONTEND}
  healthcheck:
    test: ["CMD", "wget", "-qO-", "http://127.0.0.1/"]
    start_period: 30s
    start_interval: 2s
    interval: 5m
    timeout: 5s
    retries: 3
  restart: unless-stopped
```

Use a tool the image actually has — `wget` on Alpine, `curl` on Debian-based,
`python -c` if it ships Python, `pg_isready` for Postgres. A check that cannot run
is as bad as no check.

And make it test something real. A health check that returns 200 unconditionally is
a gate that always opens — it will happily promote a build whose database
connection is broken.

### 4. `expose:`, never `ports:`

The cluster host is shared by the whole class. `ports: "8000:8000"` claims a host
port, and only one container on the machine can own it:

```
Bind for 0.0.0.0:8000 failed: port is already allocated
```

`expose:` documents the container port without binding it. Traefik reaches your
container over the internal Docker network. Your local
`docker-compose.override.yml` is where a host port binding belongs, since that file
is local-only and Coolify ignores it.

### 5. Keep a real health endpoint on the public service

Something like `/health` that returns 200 when the app can actually work — it can
reach the database, it can reach the service it depends on. It is what your health
check tests and therefore what decides whether a deploy reaches users.

### Keep the two branches the same shape

Restructure on `staging`, get it working, *then* promote. If `staging` defines
`frontend`/`backend`/`db` while `main` still has `hello`/`time`/`db`, your two
environments are running different applications, and promoting swaps production for
something that has never been tested in that environment.

### Deploy after you change shape

Renaming a service changes nothing until a deploy runs. And because Traefik bakes
routing labels in at container start, a domain change needs a deploy too. A pushed
restructure that has not deployed means what is live is still the old application —
which is a confusing state to debug, because the repo and the running containers
disagree.

### Before you push a restructure

- [ ] every service has a `healthcheck:` that uses a tool present in its image
- [ ] the public service uses `expose:`, not `ports:`
- [ ] `${SERVICE_FQDN_<SERVICE>}` matches the public service's name
- [ ] no `SERVICE_FQDN` on internal services
- [ ] `./smoke-test.sh` (or your own equivalent) passes locally
- [ ] after deploying: re-attach the domain in Coolify for **both** environments
- [ ] after that: redeploy, then load both URLs

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
| Deployed fine, then died hours later | a service in your compose file has no `healthcheck:` |
| Restructured, now the URL 404s | the domain is still attached to the old service name — section 13 |

Fuller answers in [`troubleshooting.md`](troubleshooting.md).

---

## What you just built

A push to `staging` runs your tests on a clean machine, and only if they pass
does it tell Coolify to build a new image, start it, health-check it, and swap
traffic — on infrastructure you described in a file rather than clicked into
existence. A pull request moves the same code to production under the same rules.

That is the same shape as a professional deployment pipeline. The provider would
change at a different company; almost nothing else would.
