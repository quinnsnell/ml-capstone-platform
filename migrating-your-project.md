# Migrating an Existing Project onto the Class Platform

**This page is written to be handed to a coding agent** — Codex, Claude Code,
opencode — along with your project. It states the platform's requirements
precisely enough to be acted on, rather than explaining them to a person.

**How to use it:** open your project in your agent and say something like

> Read `migrating-your-project.md` and migrate this project to run on the class
> platform. Ask me the questions in the "Decide first" section before changing
> anything.

Then read the diff before you push. You are responsible for what lands in your
repo; the agent is doing the typing.

---

## Context for the agent

The target is a shared classroom PaaS: **Coolify** on a single Linux host, fronted
by **Traefik**, deploying from GitHub via **GitHub Actions**. One repository per
student, two environments (`staging` and `production`), each running the repo's
`docker-compose.yaml` as a Docker Compose application.

The repository already contains working scaffolding generated from a template:

```
.github/workflows/ci.yml     3-job pipeline: test -> deploy-staging -> deploy-prod
docker-compose.yaml          what Coolify deploys
docker-compose.override.yml  local-only additions; Coolify ignores this file
terraform/                   creates the Coolify project, environments, applications
smoke-test.sh                local + remote endpoint check
hello/  time/                the template's example services — replace these
```

**Preserve `.github/workflows/ci.yml` and `terraform/`.** They are already wired to
this platform. Change the parts of `ci.yml` that name directories, nothing else.

---

## Decide first — ask the human these questions

Do not guess. Each wrong guess produces a deploy that appears to succeed and then
fails in a way that is hard to diagnose.

1. **Which single service is public?** Exactly one service may be reachable from a
   browser. Everything else is internal.
2. **What port does that service listen on inside its container?**
3. **Does the project have automated tests?** If so, what command runs them, and
   from which directory?
4. **Is there a database?** If it is Postgres, use the compose service described
   below. If it is something else, say so.
5. **Does anything need to persist across deploys** besides the database — uploaded
   files, model weights, a cache?

---

## Hard requirements

These are not style preferences. Each one, if violated, produces the failure named.

### R1 — Exactly one public service, and it must reference `${SERVICE_FQDN_<NAME>}`

Referencing that variable is what makes Coolify generate a route and attach Traefik
labels. The variable name is the service name, uppercased, with `-` replaced by `_`.

```yaml
services:
  frontend:                                   # public
    environment:
      APP_URL: ${SERVICE_FQDN_FRONTEND}       # the reference is what matters
```

- **Do not declare or define** `SERVICE_FQDN_*` anywhere. Only reference it.
- **Do not** put a `SERVICE_FQDN_*` reference on an internal service. Coolify will
  publish it.
- Service name and variable must agree. `web-ui` → `${SERVICE_FQDN_WEB_UI}`.

*Violation:* the application is never routed, or an internal service is exposed to
the internet.

### R2 — `expose:`, never `ports:`

The host is shared by an entire class. `ports:` claims a host port and collides.

```yaml
    expose:
      - "8000"        # documents the container port; no host binding
```

Host port bindings for local development belong in `docker-compose.override.yml`,
which Coolify does not read.

*Violation:* `Bind for 0.0.0.0:8000 failed: port is already allocated`.

### R3 — Every long-running service needs a `healthcheck:`

Coolify judges the application by its containers' Docker health. A service with no
health check reports *nothing*, which is treated as unhealthy — the deploy reports
success and the application is stopped a couple of hours later, after which the
containers (and their logs) are removed.

Use a command the image actually contains:

| Base image | Health check command |
|---|---|
| `python:*-slim` | `["CMD", "python", "-c", "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health').read()"]` |
| `node:*-alpine`, `nginx:alpine` | `["CMD", "wget", "-qO-", "http://127.0.0.1/"]` |
| Debian-based with curl | `["CMD", "curl", "-fsS", "http://127.0.0.1:8000/health"]` |
| `postgres:*` | `["CMD-SHELL", "pg_isready -U <user> -d <db>"]` |

Use this timing on every service — it confirms a new container within seconds and
then stops hammering the service:

```yaml
    healthcheck:
      test: ["CMD", "..."]
      start_period: 30s
      start_interval: 2s      # probes every 2s during start_period
      interval: 5m            # then once every 5 minutes
      timeout: 5s
      retries: 3
```

`start_interval` requires Docker Engine 25+ / Compose 2.20+.

*Violation:* clean deploy, dead application hours later, no logs left.

### R4 — The public service must serve a health endpoint that tests real dependencies

Add one if the project lacks it. It must return a 2xx only when the service can
actually do its job — reach its database, reach the services it depends on.

```python
@app.get("/health")
def health():
    try:
        db.execute("SELECT 1")
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"db unreachable: {e}")
    return {"ok": True, "version": APP_VERSION}
```

A handler that returns 200 unconditionally is a gate that always opens, and will
promote a build whose database is unreachable.

### R5 — Service-to-service communication uses compose service names

Compose provides DNS. Never use `localhost` or an IP for another service.

```
http://backend:8000        not  http://localhost:8000
postgres://user:pw@db:5432/appdb
```

### R6 — Persistent data lives on a named volume

```yaml
services:
  db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_USER=appuser
      - POSTGRES_PASSWORD=apppass
      - POSTGRES_DB=appdb
    expose:
      - "5432"
    volumes:
      - db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U appuser -d appdb"]
      start_period: 30s
      start_interval: 2s
      interval: 5m
      timeout: 5s
      retries: 5
    restart: unless-stopped

volumes:
  db-data:
```

Coolify gives each environment its own volume, so staging and production never
share data. Anything written outside a named volume is lost on every deploy.

### R7 — Schema is created by the application, not by hand

There is no opportunity to run migrations manually against the deployed database.
Apply them on startup — a FastAPI lifespan hook, Django `migrate`, Alembic
`upgrade head`, whatever the stack uses — so every deploy converges the schema.

### R8 — Every service needs `restart: unless-stopped`

---

## Target shape

```yaml
services:
  <public service>:        # R1 reference, expose, healthcheck, restart
  <internal services>:     # expose, healthcheck, restart — no SERVICE_FQDN
  db:                      # named volume, healthcheck, restart

volumes:
  db-data:
```

Add `depends_on` with `condition: service_healthy` wherever startup order matters.
This is why R3 applies to internal services too — `depends_on: service_healthy`
requires the dependency to *have* a health check.

---

## Also update these

### `.github/workflows/ci.yml`

Only the `test` job references directories. It currently reads:

```yaml
      - name: Install dependencies
        run: pip install -r hello/requirements.txt httpx pytest
      - name: Unit tests
        run: cd hello && pytest tests/ -v
```

Point those at the real locations. **Leave the `deploy-staging` and `deploy-prod`
jobs alone** — their `needs: test` and `if: github.ref == ...` conditions are the
deployment policy, and the secret names are already provisioned.

If the project has no tests yet, make the `test` job do something real that fails on
broken code — a lint, an import check, a build. Do not delete the job: the deploy
jobs depend on it, and removing the gate removes the point of the pipeline.

### `smoke-test.sh`

It currently curls the template's endpoints (`/`, `/health`, `/time`, `/notes`).
Rewrite the endpoint list for the real application, keeping both modes: no argument
means `docker compose up` locally then test `localhost`, and one argument means test
that URL without touching Docker.

### `docker-compose.override.yml`

Local-only. Host port bindings and development environment variables go here.

### `terraform/`

No changes needed. It creates Coolify projects and applications and does not care
what the services are called.

---

## Do not

- Do not use `ports:` in `docker-compose.yaml` (R2)
- Do not add `SERVICE_FQDN_*` to more than one service (R1)
- Do not declare `SERVICE_FQDN_*` as a variable — only reference it
- Do not remove the `test` job from `ci.yml`, or the `needs:`/`if:` conditions
- Do not commit secrets. `terraform/terraform.tfvars` holds live credentials and is
  gitignored; keep it that way
- Do not set the deployed domain in `docker-compose.yaml` — a human does that in
  Coolify's UI, per service
- Do not assume `localhost` reaches another container (R5)

---

## Verify before pushing

Run these and report the results. Do not claim success without them.

```bash
# 1. the compose file is valid and has no host port bindings
SERVICE_FQDN_<PUBLIC>=http://localhost:<port> docker compose config >/dev/null && echo "compose OK"
grep -n "ports:" docker-compose.yaml && echo "FAIL: ports: in the deployed compose file"

# 2. every service has a healthcheck — count them
grep -c "healthcheck:" docker-compose.yaml     # must equal the number of services

# 3. it builds and every service becomes healthy
SERVICE_FQDN_<PUBLIC>=http://localhost:<port> docker compose up -d --build
docker compose ps                               # every service: healthy

# 4. the health endpoint answers
curl -fsS localhost:<port>/health

# 5. the smoke test passes
./smoke-test.sh

# 6. clean up
docker compose down
```

A service stuck at `health: starting` means its health check command is wrong —
usually a tool the image does not have. Check with
`docker compose exec <service> which curl wget`.

---

## Tell the human what they must do by hand

Finish by reporting this, because it cannot be automated from the repository:

1. **Re-attach the domain in Coolify for both environments** — Access → gear on the
   configured domain → the service name may have changed, so the domain must be
   pointed at the new public service. Protocol `http`, no port, no path.
2. **Redeploy after that**, because Traefik bakes routing labels in at container
   start — a domain changed after deployment leaves the URL returning 404.
3. **Both branches should end up the same shape.** If the migration happened on
   `staging` only, promoting to `main` will deploy a different application to
   production than the one that was tested.

Also report: which service is public, what the health endpoint checks, what the
`test` job now runs, and anything that was guessed rather than asked.
