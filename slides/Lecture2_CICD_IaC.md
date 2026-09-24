# Lecture 2 — CI/CD, the Cloud, and Infrastructure as Code

Companion notes for `Lecture2_CICD_IaC.pptx` (43 slides).

---

## What this lecture is for

Students finish Mike's session able to build an image, run a container, and push
to GitHub. They can make software run **on their own machine**. This lecture is
the bridge to making it run **for other people** — and to doing that so routinely
that it stops being an event.

Three questions, in order:

1. **Where does everything sit?** They cannot reason about a deploy until they
   can picture the machines involved and what each one owns.
2. **What happens between `git push` and a user seeing the change?** Every step,
   who runs it, and where it is allowed to stop.
3. **Who created all that infrastructure, and how do we avoid doing it by hand?**
   Which is the door into IaC and Terraform.

The through-line: **describe it, don't do it.** A Dockerfile describes an image.
A compose file describes a system. A workflow describes a pipeline. A `.tf` file
describes infrastructure. They have been doing this since lab 1 without the name.

---

## The arc

| Slides | Beat | The point |
|---|---|---|
| 1–4 | Where you are, and the gap | "Works on my machine" is solved; "works for users" isn't |
| **5** | **Architecture diagram** | The mental model everything else hangs on |
| 6–10 | Walk each piece | Laptop, GitHub, cloud host, users, why two environments |
| 11–12 | CI/CD defined | Not about speed — about being *the same every time* |
| **13** | **Ten-step flow** | Where the gate is, and what never runs when tests fail |
| 14–20 | The mechanics | Jobs, secrets, container swap, health checks, failure |
| 21–25 | Why IaC exists | Thirty clicks × thirty students × every semester |
| 26–34 | Terraform | Four ideas, then their actual file, then state |
| 35 | What it *can't* do | Honest IaC: automate 90%, document the 10% |
| **36–37** | **Portability** | The shape survives the provider change |
| 38–43 | Context and their turn | Alternatives, compose as IaC, how to judge generated code |

Rough timing: ~15 min architecture, ~25 min CI/CD, ~30 min IaC/Terraform, plus
demo time. Slides 5, 13 and 32 are worth dwelling on; most of the bullet slides
are 60–90 seconds each.

---

## You have a live system to demo

This is the biggest advantage over teaching it abstractly. Everything below is
real and running right now (CS VPN required).

| What | Where |
|---|---|
| Demo repo | `github.com/byu-ml-capstone/hello-test-qsnell` |
| Staging | http://hello-test-qsnell-staging.ml-capstone.cs.byu.edu |
| Production | http://hello-test-qsnell.ml-capstone.cs.byu.edu |
| Coolify | https://ml-capstone-admin.cs.byu.edu |
| Template | `github.com/byu-ml-capstone/hello-world-app` |

**The demo that makes slide 13 land.** Bump `APP_VERSION` in `hello/greetings.py`,
push to `staging`, and put three windows up: the GitHub Actions run, Coolify's
deployment log, and `curl .../health` in a loop. Students watch the version
change under them. Total elapsed time is under two minutes.

```bash
watch -n2 'curl -s http://hello-test-qsnell-staging.ml-capstone.cs.byu.edu/health'
```

Then show production still on the old version — that is the "two environments"
point made concrete, and it lands harder than the slide does.

**The failure demo is better than the success demo.** Break a test deliberately,
push, and let them watch `deploy-staging` never start. The live URL keeps serving
the old version throughout. That is the whole argument for tests-gate-deploy in
thirty seconds.

**For the Terraform section**, `terraform plan` against the demo project prints
`No changes. Your infrastructure matches the configuration.` — which is the most
convincing possible demonstration of what declarative means. If you want to show
a real plan, add a line to a variable default and re-plan.

---

## Slide notes

### 5 — The System, End to End

Spend real time here. Everything later refers back to it.

Walk it in the direction the code moves: laptop → GitHub → cloud → users. Three
things students routinely get wrong, so say them out loud:

- **The same three services run in all three places.** The compose file on their
  laptop is the compose file production uses. Not "similar" — the same file.
- **GitHub is not just storage.** Actions is a computer that runs their tests.
- **Staging and production do not share a database.** Separate volumes. Wiping
  staging data is safe; that is what it is for.

Worth naming: `hello` is the only service users can reach. `time` and `db` have
no public route at all — not a firewall rule, they simply have no hostname.

### 6–9 — Walking the pieces

Short slides, one idea each. The one to dwell on is **Users**: wildcard DNS means
`*.ml-capstone.cs.byu.edu` all resolves to the same host, and Traefik decides
which container answers based on the hostname in the request. That is why thirty
students share one machine without colliding, and why their **repo name becomes
their URL**.

### 10 — Why two environments

The line that works: *"Production should be boring. Staging is where you find out
you were wrong."*

### 13 — One Push, Step by Step

The red band is the slide. Everything above it is mechanics; the red band is the
policy. Ask them: *what is the longest a broken commit can be live?* Answer: it
never is — it does not get that far.

Steps 1, 6 and 8 are the only ones a human does. Everything else was configured
once and now happens whether anyone is watching or not.

### 15 — The YAML

Two lines carry the entire policy:

```yaml
needs: test                                # deploy cannot start unless tests passed
if: github.ref == 'refs/heads/staging'     # this branch, this environment
```

Everything else in the file is plumbing. If they understand these two lines they
can read any CI config they meet later.

### 17–18 — Container swap and health checks

The insight worth landing: **a container that starts is not an app that works.**
Coolify polls `/health` and only moves traffic when it answers. So `/health` is
not decoration — it is the last automated judgment about whether users get the
new code.

Which means a `/health` that returns `{"ok": true}` unconditionally is worse than
useless: it is a gate that always opens. Push them to check what would actually
break — the database connection, the service they depend on.

### 22 — How We Got Here

Be concrete and a little rueful: creating one student's setup by hand is about
thirty clicks across two websites. Thirty students is thirty repetitions, and a
mistake anywhere is silent until their deploy fails. That is the motivation for
everything in the rest of the lecture — and it is a real story, not a hypothetical.

### 25 — Imperative vs Declarative

The test for declarative is: **run it twice, get the same result.** A shell script
that creates a project creates two projects. `terraform apply` run twice does
nothing the second time. That property is called idempotence and it is why the
whole approach works.

### 29–33 — Their actual file

This is the heart of the Terraform section. Keep it concrete — this is not
Terraform in general, it is the file sitting in `terraform/` of their own repo.

- **Provider block** — two providers, because this deploy touches two platforms.
  Versions pinned, so everyone gets the same behavior all semester.
- **Variables** — the parameters. The `coolify_server_uuid` validation is a good
  example: every team has a *different* server UUID, so there is no default that
  works, and the validation turns a confusing API error into an instruction.
- **Resources** — note `coolify_project.app.uuid` appearing inside the environment
  resource. That reference is the whole trick.
- **Slide 32** — because of those references, Terraform builds a graph and works
  out the order itself. They never write "create the project first."
- **Outputs** — the facts that did not exist until the infrastructure did.

### 34 — State

The part that confuses everyone. `terraform.tfstate` is how Terraform knows what
it already made. Delete it and Terraform forgets, then tries to create duplicates
of things that already exist. It can contain secrets, which is why it is
gitignored. Real teams keep it in shared remote storage; students keep it local.

### 35 — What It Cannot Do

Do not skip this one. The provider cannot set a per-service domain on a Docker
Compose app, so that step stays manual and is *documented* as manual. The lesson
is professional rather than technical: a fragile automation that fights the tool
is worse than an honest checklist. Ninety percent automated with a written-down
remainder beats a brittle hundred.

### 36–37 — Portability

The payoff slide, and the answer to *"why learn Coolify, I'll never use it again."*

What changes: the provider block, the resource type names, their arguments.
What doesn't: their app, the Dockerfile, the compose file, the CI pipeline, the
variables, the outputs, the structure, and the way they think about it.

Slide 37 puts `coolify_application` and `aws_apprunner_service` side by side —
different nouns, identical position in an identical graph.

### 40–41 — Their turn

They will generate these files with Claude, Codex, or opencode, and that is fine
— it is exactly why the pieces matter. Generated code you cannot evaluate is a
liability, not a shortcut. Slide 41 is the checklist for interrogating what comes
back: pinned versions, unexpected resources, correct references, no hard-coded
secrets, and a `plan` that shows exactly what you expect and nothing more.

---

## Questions students actually ask

**"Why not just deploy from my laptop?"**
Because then the deploy depends on your laptop, your network, your environment
variables, and you remembering the steps. And nobody else can do it.

**"Why do tests run on GitHub's computer instead of mine?"**
Because yours is not a clean room. CI runs on a fresh machine every time, so
"works for me" cannot hide a missing dependency.

**"What if I push straight to main?"**
It deploys to production — after tests pass. Nothing stops you. That is a social
rule, not a technical one, which is exactly why teams use pull requests.

**"Why is `/health` special?"**
Coolify polls it to decide whether the new container replaces the old one.
It is the one endpoint with power over your users.

**"Do I have to use Terraform?"**
No — the Coolify UI does the same thing. Path B in the student guide. Terraform
is faster, reviewable, and repeatable; the UI shows you what is being created.
Doing it both ways is not wasted time.

**"Why is the domain step manual if we have IaC?"**
Because the provider does not support it. Honest limits beat pretend automation.

---

## Have open before you start

- The deck
- The architecture diagram, ideally on a second screen for the whole lecture
- A terminal on the CS VPN
- `hello-test-qsnell` in GitHub, on the Actions tab
- Coolify, on the demo project
- Both live URLs in browser tabs

---

## What happens next

After this lecture students do the setup lab in `student-guide.md` Part B. At the
fork they choose **Path A (Terraform)** or **Path B (Coolify UI)** — both end in
the same place, and both set their two domains by hand. Then Step 10 walks them
through their first real deploy, including a deliberately failing test so they
watch the gate work.

Everything in this lecture is documented at
<https://quinnsnell.github.io/ml-capstone-platform/> — the student guide, the
template app README, and the Terraform lab.
