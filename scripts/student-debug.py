#!/usr/bin/env python3
"""
student-debug.py — see how far students got, and why one is stuck.

    ./scripts/student-debug.py                 progress table for everyone
    ./scripts/student-debug.py oliphant        everything about one student

With no argument it answers "who needs help". With a name it answers "why", by
checking the things that actually go wrong rather than printing raw state:

  - did terraform run      project + two environments + two applications
  - are domains set        and attached to a service that still exists
  - did it deploy          deployment history and last status
  - is it running          containers, health, and a live HTTP request
  - will it stay up        every long-running compose service needs a
                           healthcheck; one that reports nothing is treated as
                           unhealthy and gets stopped hours after a clean deploy
  - is SERVICE_FQDN right  the variable must match the public service's name
  - do the branches agree  compose rewritten on staging only means promoting
                           deploys a different application to production

Requires: the CS VPN, ssh to the Coolify host, and the gh CLI.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

COOLIFY_HOST = "rigel"
ORG = "byu-ml-capstone"
DOMAIN_BASE = "ml-capstone.cs.byu.edu"
DB = "docker exec -i coolify-db psql -U coolify -d coolify -At -F'~'"

C_OK, C_BAD, C_WARN, C_DIM, C_B, C_Z = (
    "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[1m", "\033[0m"
) if sys.stdout.isatty() else ("",) * 6


def ssh(cmd: str) -> str:
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", COOLIFY_HOST, cmd],
                       capture_output=True, text=True, timeout=120)
    return r.stdout


def sql(query: str) -> list[list[str]]:
    out = ssh(f"{DB} -c \"{query.strip().replace(chr(10), ' ')}\"")
    return [l.split("~") for l in out.splitlines() if l.strip() and "~" in l]


def containers() -> dict[str, list[tuple[str, bool]]]:
    """uuid -> [(service, healthy)] for every running app container."""
    out = ssh('docker ps --format "{{.Names}}~{{.Status}}"')
    found: dict[str, list[tuple[str, bool]]] = {}
    for line in out.splitlines():
        if "~" not in line:
            continue
        name, status = line.split("~", 1)
        m = re.match(r"^([a-z0-9_-]+?)-([a-z0-9]{20,})-\d+$", name)
        if m:
            found.setdefault(m.group(2), []).append((m.group(1), "healthy" in status))
    return found


def real_domains(blob: str) -> list[tuple[str, str]]:
    """[(service, hostname)] for domains that aren't Coolify's sslip.io filler."""
    if not blob:
        return []
    try:
        data = json.loads(blob)
    except Exception:
        return []
    out = []
    for svc, v in data.items():
        for d in (v.get("domain") or "").split(","):
            d = d.strip()
            if d and "sslip.io" not in d:
                out.append((svc, re.sub(r"^https?://", "", d)))
    return out


def fetch_apps() -> list[dict]:
    rows = sql("""
      SELECT t.name, COALESCE(p.name,''), COALESCE(e.name,''), COALESCE(a.uuid,''),
             COALESCE(a.git_branch,''), COALESCE(a.docker_compose_domains,''),
             COALESCE(a.status,''), COALESCE(a.id::text,''),
             COALESCE((SELECT status FROM application_deployment_queues q
                       WHERE q.application_id=a.id::text ORDER BY q.id DESC LIMIT 1),''),
             COALESCE((SELECT count(*)::text FROM application_deployment_queues q
                       WHERE q.application_id=a.id::text),'0')
      FROM teams t
      LEFT JOIN projects p ON p.team_id=t.id
      LEFT JOIN environments e ON e.project_id=p.id
      LEFT JOIN applications a ON a.environment_id=e.id
      WHERE t.id>0 ORDER BY t.name, e.name;
    """)
    keys = ("team project env uuid branch domains status appid last ndeploys").split()
    return [dict(zip(keys, (r + [""] * 10)[:10])) for r in rows]


def http(url: str) -> str:
    r = subprocess.run(["curl", "-sS", "-m", "20", "-o", "/dev/null",
                        "-w", "%{http_code}", url], capture_output=True, text=True)
    return r.stdout.strip() or "---"


# ---------------------------------------------------------------- fleet view
def overview(apps, running):
    teams: dict[str, list[dict]] = {}
    for a in apps:
        teams.setdefault(a["team"], []).append(a)

    print(f"\n{C_B}{'STUDENT':<34} {'TERRAFORM':<10} {'DOMAINS':<8} "
          f"{'DEPLOYS':<8} {'UP':<4} LAST{C_Z}")
    print("-" * 86)
    tally = {"not started": 0, "partial": 0, "deployed": 0, "live": 0}
    for team in sorted(teams):
        rows = [r for r in teams[team] if r["uuid"]]
        doms = [d for r in rows for d in real_domains(r["domains"])]
        deploys = sum(int(r["ndeploys"] or 0) for r in rows)
        up = sum(1 for r in rows if r["uuid"] in running)
        last = max((r["last"] for r in rows if r["last"]), default="")

        if len(rows) >= 2:
            tf, col = "complete", C_OK
        elif rows:
            tf, col = "partial", C_WARN
            tally["partial"] += 1
        else:
            tf, col = "-", C_DIM
            tally["not started"] += 1
        if deploys:
            tally["deployed"] += 1
        if up:
            tally["live"] += 1

        flag = C_BAD if (deploys and not up) else ""
        print(f"{team[:33]:<34} {col}{tf:<10}{C_Z} {len(doms):<8} "
              f"{deploys:<8} {flag}{up:<4}{C_Z} {last}")

    print(f"\n  {len(teams)} teams · {tally['not started']} not started · "
          f"{tally['partial']} partial · {tally['deployed']} have deployed · "
          f"{tally['live']} running now")
    stuck = [t for t in sorted(teams)
             if sum(int(r['ndeploys'] or 0) for r in teams[t] if r['uuid'])
             and not any(r["uuid"] in running for r in teams[t] if r["uuid"])]
    if stuck:
        print(f"\n{C_BAD}  Deployed but nothing running — look at these first:{C_Z}")
        for t in stuck:
            print(f"    {t}")
        print(f"{C_DIM}    ./scripts/student-debug.py <name>{C_Z}")


# --------------------------------------------------------------- deep dive
def compose_for(repo: str, ref: str) -> str | None:
    r = subprocess.run(
        ["gh", "api", f"/repos/{ORG}/{repo}/contents/docker-compose.yaml?ref={ref}",
         "--jq", ".content"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    import base64
    try:
        return base64.b64decode(r.stdout.strip()).decode("utf-8", "replace")
    except Exception:
        return None


def compose_services(text: str) -> dict[str, dict]:
    """Top-level service names and which keys each carries.

    Tracks the enclosing top-level block, because `volumes:` and `networks:`
    entries sit at the same indentation as services and would otherwise be
    reported as services with no healthcheck.
    """
    svcs: dict[str, dict] = {}
    block, cur = None, None
    for line in text.split("\n"):
        if re.match(r"^[a-zA-Z]", line):                 # top-level key
            block = line.split(":", 1)[0].strip()
            cur = None
            continue
        if block != "services":
            continue
        m = re.match(r"^  ([a-zA-Z0-9_.-]+):\s*$", line)
        if m:
            cur = m.group(1)
            svcs[cur] = {"healthcheck": False, "restart": False,
                         "expose": False, "ports": False, "fqdn": None}
            continue
        if not cur:
            continue
        # Strip comments before looking for anything. The template explains
        # ${SERVICE_FQDN_*} in prose inside the file, and those mentions would
        # otherwise be read as real references -- including one for `time`
        # sitting above the `time:` key, which got attributed to the previous
        # service and made every unmodified template look misconfigured.
        line = re.sub(r"(^|\s)#.*$", "", line)
        if not line.strip():
            continue
        if re.match(r"^    healthcheck:", line):
            svcs[cur]["healthcheck"] = True
        elif re.match(r"^    restart:", line):
            svcs[cur]["restart"] = True
        elif re.match(r"^    expose:", line):
            svcs[cur]["expose"] = True
        elif re.match(r"^    ports:", line):
            svcs[cur]["ports"] = True
        fq = re.search(r"\$\{SERVICE_FQDN_([A-Z0-9_]+)\}", line)
        if fq and not svcs[cur]["fqdn"]:
            svcs[cur]["fqdn"] = fq.group(1)
    return svcs


def ok(msg):   print(f"  {C_OK}ok  {C_Z} {msg}")
def bad(msg):  print(f"  {C_BAD}FAIL{C_Z} {msg}")
def warn(msg): print(f"  {C_WARN}warn{C_Z} {msg}")
def note(msg): print(f"       {C_DIM}{msg}{C_Z}")


def deep_dive(needle, apps, running):
    hits = {a["team"] for a in apps
            if needle.lower() in a["team"].lower()
            or needle.lower() in (a["project"] or "").lower()}
    if not hits:
        print(f"No team or project matching {needle!r}.")
        return
    if len(hits) > 1:
        print("Matches more than one — be more specific:")
        for h in sorted(hits):
            print(f"  {h}")
        return
    team = hits.pop()
    rows = [a for a in apps if a["team"] == team]
    live = [r for r in rows if r["uuid"]]

    print(f"\n{C_B}{team}{C_Z}")
    project = next((r["project"] for r in rows if r["project"]), None)
    if not project:
        bad("no Coolify project — terraform has not run (or the UI path was not started)")
        return
    print(f"  project: {project}\n")

    # --- terraform shape
    envs = sorted({r["env"] for r in live})
    if len(live) >= 2 and {"staging", "production"} <= set(envs):
        ok(f"terraform shape: {len(live)} applications across {', '.join(envs)}")
    else:
        bad(f"incomplete: {len(live)} application(s), environments {envs or 'none'}")
        note("terraform apply creates two environments and two applications")
    if len(live) > 2:
        warn(f"{len(live)} applications where there should be 2 — extras confuse everything after")
        for r in live:
            note(f"{r['env']:<11} branch={r['branch'] or '?':<8} {r['uuid']}")

    # --- per application
    for r in sorted(live, key=lambda x: x["env"]):
        print(f"\n  {C_B}{r['env']}{C_Z}  branch={r['branch'] or '?'}  uuid={r['uuid']}")
        print(f"       status={r['status'] or '?'}  deploys={r['ndeploys']}  last={r['last'] or 'never'}")
        doms = real_domains(r["domains"])
        if doms:
            for svc, host in doms:
                ok(f"domain {host}  -> service '{svc}'")
        else:
            bad("no real domain set — only Coolify's sslip.io placeholder, if any")
            note("lab step 10; Traefik has no route until this is done")
        svcs_up = running.get(r["uuid"], [])
        if svcs_up:
            ok("containers: " + ", ".join(
                f"{s}{'' if h else C_WARN+'(unhealthy)'+C_Z}" for s, h in sorted(svcs_up)))
        elif int(r["ndeploys"] or 0):
            bad("no containers running, despite having deployed")
            note("if status is exited:unhealthy, suspect a service with no healthcheck")
        else:
            note("never deployed")
        for svc, host in doms:
            print(f"       http://{host}/health -> {http(f'http://{host}/health')}")

    # --- compose analysis, the part that explains "deployed then died"
    repo = project
    shapes = {}
    for ref in ("main", "staging"):
        text = compose_for(repo, ref)
        if text:
            shapes[ref] = compose_services(text)
    if not shapes:
        print()
        warn(f"could not read docker-compose.yaml from {ORG}/{repo} (private, or renamed)")
        return

    print(f"\n  {C_B}docker-compose.yaml{C_Z}")
    for ref, svcs in shapes.items():
        print(f"       {ref}: {', '.join(svcs) or 'no services found'}")
    if len(shapes) == 2 and set(shapes["main"]) != set(shapes["staging"]):
        warn("main and staging define different services")
        note("normal while restructuring, but promoting now would deploy a")
        note("different application to production than the one tested")

    # Running containers vs what the branch currently defines. A mismatch means
    # a restructure has been pushed but not deployed -- and the next deploy will
    # behave differently from what is live now.
    for r in sorted(live, key=lambda x: x["env"]):
        up = {s for s, _ in running.get(r["uuid"], [])}
        want = set(shapes.get(r["branch"] or "", {}))
        if up and want and up != want:
            warn(f"{r['env']}: running [{', '.join(sorted(up))}] but "
                 f"{r['branch']} now defines [{', '.join(sorted(want))}]")
            note("a restructure has been pushed but not deployed; the next deploy changes shape")

    svcs = shapes.get("staging") or shapes.get("main") or {}
    missing = [s for s, v in svcs.items() if not v["healthcheck"]]
    if missing:
        bad(f"no healthcheck on: {', '.join(missing)}")
        note("Coolify judges the app by container health; a service that reports")
        note("nothing is treated as unhealthy and stopped hours after a clean deploy")
    elif svcs:
        ok("every service has a healthcheck")
    for s, v in svcs.items():
        if v["ports"]:
            warn(f"'{s}' uses ports: — on the shared host this collides; use expose:")
    published = {svc for svc, _ in
                 [d for r in live for d in real_domains(r["domains"])]}
    for svc in published:
        want = svc.upper().replace("-", "_")
        holder = [s for s, v in svcs.items() if v["fqdn"] == want]
        if svcs and not holder:
            bad(f"domain is on '{svc}' but no service references ${{SERVICE_FQDN_{want}}}")
            note("without that reference Coolify will not route to it")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("student", nargs="?", help="name, team or project substring")
    args = ap.parse_args()

    apps = fetch_apps()
    if not apps:
        print("No data from Coolify. On the CS VPN? ssh to the Coolify host working?")
        sys.exit(1)
    running = containers()
    if args.student:
        deep_dive(args.student, apps, running)
    else:
        overview(apps, running)


if __name__ == "__main__":
    main()
