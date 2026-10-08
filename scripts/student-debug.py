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
def roster() -> dict[str, dict] | None:
    """team_name -> {name, github_username}, so demo teams don't pad the counts
    and we can look for each student's repo in the org."""
    import csv, glob, os
    files = [f for f in glob.glob(os.path.join(os.path.dirname(os.path.dirname(
             os.path.abspath(__file__))), "roster-*.csv")) if "example" not in f]
    if not files:
        return None
    newest = max(files, key=os.path.getmtime)
    with open(newest, newline="") as fh:
        return {r["team_name"].strip(): r for r in csv.DictReader(fh)
                if r.get("team_name") and not r["team_name"].startswith("#")}


def repo_owners() -> dict[str, str]:
    """github login (lowercased) -> one of their repos in the org.

    Uses each repo's direct collaborators rather than matching names against
    repo names: students name repos freely -- kademiester2003 owns
    kartchner-demo, JansenNye owns jnye-capstone-project -- so name matching
    produces both false positives and false negatives.
    """
    from concurrent.futures import ThreadPoolExecutor
    r = subprocess.run(["gh", "api", f"/orgs/{ORG}/repos", "--paginate",
                        "--jq", ".[].name"], capture_output=True, text=True)
    repos = [x.strip() for x in r.stdout.split("\n") if x.strip()]

    def collaborators(repo):
        out = subprocess.run(
            ["gh", "api", f"/repos/{ORG}/{repo}/collaborators?affiliation=direct",
             "--jq", ".[].login"], capture_output=True, text=True)
        return repo, [x.strip().lower() for x in out.stdout.split("\n") if x.strip()]

    owners: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        for repo, logins in pool.map(collaborators, repos):
            for login in logins:
                owners.setdefault(login, repo)
    return owners


LAB_STEP = {
    "not started":  "1-8",
    "no domains":   "10",
    "not deployed": "11",
    "staging only": "12",
    "LIVE":         "done",
    "BROKEN":       "11",
    "stuck?":       "11",
}


# Worst first: the point of the table is to show who needs attention.
STATUS_ORDER = [
    ("BROKEN",        C_BAD,  "deployed, nothing running"),
    ("stuck?",        C_BAD,  "deploy failed"),
    ("no domains",    C_WARN, "terraform done, step 10 not done"),
    ("not deployed",  C_WARN, "configured, never pushed"),
    ("staging only",  C_DIM,  "not promoted to production yet"),
    ("LIVE",          C_OK,   "both environments running"),
    ("not started",   C_DIM,  ""),
]


def classify(apps_for_team, running):
    rows = [a for a in apps_for_team if a["uuid"]]
    doms = [d for r in rows for d in real_domains(r["domains"])]
    deploys = sum(int(r["ndeploys"] or 0) for r in rows)
    up = sum(1 for r in rows if r["uuid"] in running)
    last = max((r["last"] for r in rows if r["last"]), default="")

    if not rows:
        st = "not started"
    elif deploys and not up:
        st = "BROKEN"
    elif last == "failed":
        st = "stuck?"
    elif not deploys and not doms:
        st = "no domains"
    elif not deploys:
        st = "not deployed"
    elif up >= 2:
        st = "LIVE"
    else:
        st = "staging only"
    return st, len(rows), len(doms), deploys, up, last


def overview(apps, running, show_all=False):
    teams: dict[str, list[dict]] = {}
    for a in apps:
        teams.setdefault(a["team"], []).append(a)

    people = roster()
    if people:
        extra = {t for t in teams if t not in people}
        teams = {t: v for t, v in teams.items() if t in people}
    else:
        people, extra = {}, set()

    # One call, so "not started" can be split into "no repo yet" (step 1) and
    # "repo exists, terraform has not run" (somewhere in 2-8).
    # Only worth the API sweep if someone has no Coolify project at all.
    need = any(not [a for a in v if a["uuid"]] for v in teams.values())
    owners = repo_owners() if (people and need) else {}

    rank = {name: i for i, (name, _, _) in enumerate(STATUS_ORDER)}
    colour = {name: c for name, c, _ in STATUS_ORDER}
    rows = []
    for team in teams:
        st, napps, ndom, dep, up, last = classify(teams[team], running)
        step = LAB_STEP.get(st, "?")
        if st == "not started":
            gh_user = (people.get(team, {}).get("github_username") or "").lower()
            step = "2-8" if owners.get(gh_user) else "1"
        rows.append((rank[st], team, st, step, napps, ndom, dep, up, last))
    rows.sort(key=lambda r: (r[0], r[1]))

    # Collapse the two bands that need no action, so the default output fits on
    # a screen. Everything is still there with --all.
    COLLAPSE = {} if show_all else {"LIVE", "not started"}

    def wrap(names, width=86, indent="     "):
        line, out = indent, []
        for n in names:
            piece = n + ", "
            if len(line) + len(piece) > width:
                out.append(line.rstrip().rstrip(","))
                line = indent
            line += piece
        if line.strip():
            out.append(line.rstrip().rstrip(","))
        return out

    print(f"\n{C_B}{'STUDENT':<32}{'ON STEP':<9}{'STATUS':<14}{'APPS':>5}{'DOM':>5}"
          f"{'DEPL':>6}{'UP':>4}  LAST{C_Z}")
    print("─" * 88)
    last_rank, collapsed = None, {}
    for rk, team, st, step, napps, ndom, dep, up, last in rows:
        name = team.replace("'s Sandbox", "")[:31]
        if st in COLLAPSE:
            collapsed.setdefault(st, []).append(name)
            continue
        if last_rank is not None and rk != last_rank:
            print()
        last_rank = rk
        c = colour[st]
        print(f"{name:<32}{step:<9}{c}{st:<14}{C_Z}{napps:>5}{ndom:>5}"
              f"{dep:>6}{up:>4}  {last}")

    for st in ("LIVE", "not started"):
        if st in collapsed:
            c = colour[st]
            print(f"\n{c}{st}{C_Z} ({len(collapsed[st])}) "
                  f"{C_DIM}— use --all to list them as rows{C_Z}")
            for l in wrap(sorted(collapsed[st])):
                print(l)

    counts: dict[str, int] = {}
    for r in rows:
        counts[r[2]] = counts.get(r[2], 0) + 1
    steps: dict[str, int] = {}
    for r in rows:
        steps[r[3]] = steps.get(r[3], 0) + 1
    print("─" * 82)
    print(f"{len(rows)} students")
    for name, c, hint in STATUS_ORDER:
        if counts.get(name):
            print(f"  {c}{counts[name]:>3} {name:<14}{C_Z}{C_DIM}{hint}{C_Z}")
    if extra:
        print(f"{C_DIM}  (ignored {len(extra)} non-roster team(s): {', '.join(sorted(extra))}){C_Z}")

    order = ["1", "2-8", "10", "11", "12", "done"]
    label = {"1": "step 1 — no repo in the org yet",
             "2-8": "steps 2-8 — repo exists, terraform has not run",
             "10": "step 10 — set your two domains",
             "11": "step 11 — push to staging",
             "12": "step 12 — promote to production",
             "done": "finished the lab"}
    print(f"\n{C_B}Where the class is{C_Z}")
    for k in order:
        if steps.get(k):
            print(f"  {steps[k]:>3}  {label[k]}")

    todo = [r[1] for r in rows if r[2] in ("BROKEN", "stuck?")]
    if todo:
        print(f"\n{C_BAD}Needs help now:{C_Z}")
        for t in todo:
            print(f"  {t}   ->  ./scripts/student-debug.py '{t.split()[0]}'")


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


# ------------------------------------------------- step 13: their own project
# The lab ends with the stock template deployed. The real assignment is to
# replace it with their own project, which is visible in the compose file: the
# template's services are `hello`, `time` and `db`, so anything else is theirs.
STOCK = {"hello", "time", "db"}


def project_shapes(repos: list[str]) -> dict[str, dict]:
    """repo -> {"main": set|None, "staging": set|None} of compose service names.

    None means the file could not be read on that branch -- missing, renamed,
    or the branch does not exist. Two API calls per student, so it runs in a
    pool; serially this takes a minute for a class of thirty.
    """
    from concurrent.futures import ThreadPoolExecutor

    def one(job):
        repo, ref = job
        text = compose_for(repo, ref)
        return repo, ref, (set(compose_services(text)) if text else None)

    jobs = [(r, ref) for r in repos for ref in ("main", "staging")]
    out: dict[str, dict] = {r: {} for r in repos}
    with ThreadPoolExecutor(max_workers=12) as pool:
        for repo, ref, svcs in pool.map(one, jobs):
            out[repo][ref] = svcs
    return out


# rank, label, colour -- least progress first
MIGRATION = [
    (0, "no repo",   C_DIM),
    (1, "template",  C_DIM),
    (2, "main only", C_WARN),
    (3, "staging",   C_WARN),
    (4, "migrated",  C_OK),
]
MIG_RANK = {lab: r for r, lab, _ in MIGRATION}
MIG_COLOUR = {lab: c for _, lab, c in MIGRATION}


def migration_state(shape: dict | None) -> tuple[str, set]:
    """(label, the service set that best represents their work)."""
    if not shape or (shape.get("main") is None and shape.get("staging") is None):
        return "no repo", set()
    main, stg = shape.get("main"), shape.get("staging")
    own = lambda sv: sv is not None and bool(sv - STOCK)
    if own(main) and own(stg):
        return "migrated", stg
    if own(stg):
        return "staging", stg
    if own(main):
        return "main only", main
    return "template", (stg or main or set())


def project_view(apps, running):
    teams: dict[str, list[dict]] = {}
    for a in apps:
        teams.setdefault(a["team"], []).append(a)

    people = roster()
    if people:
        teams = {t: v for t, v in teams.items() if t in people}
    else:
        people = {}

    # The Coolify project name is normally the repo name -- but a student with
    # a hand-made project ("Product management tool") breaks that, and one with
    # no project at all still has a repo. So collect every candidate per team
    # and keep whichever actually yields a compose file.
    owners = repo_owners()
    cands: dict[str, list[str]] = {}
    for team, rows in teams.items():
        seen = []
        for r in rows:
            if r["project"] and r["project"] not in seen:
                seen.append(r["project"])
        gh = (people.get(team, {}).get("github_username") or "").lower()
        if owners.get(gh) and owners[gh] not in seen:
            seen.append(owners[gh])
        cands[team] = seen

    shapes = project_shapes(sorted({c for v in cands.values() for c in v}))

    rows = []
    for team, apps_for_team in teams.items():
        st, napps, ndom, dep, up, last = classify(apps_for_team, running)
        # Best candidate = the one showing the most migration progress; a repo
        # whose compose could not be read ranks last and only wins if it is all
        # there is.
        best = max(cands[team] or [""],
                   key=lambda c: MIG_RANK[migration_state(shapes.get(c))[0]])
        repo = best
        mig, svcs = migration_state(shapes.get(repo))
        lab_done = st == "LIVE"
        rows.append({
            "team": team, "lab": st, "lab_done": lab_done, "napps": napps,
            "mig": mig, "svcs": svcs, "repo": repo,
        })

    # Sort: everyone still inside the lab first (they cannot migrate yet),
    # then by how far the migration has actually got.
    rows.sort(key=lambda r: (r["lab_done"], MIG_RANK[r["mig"]], r["team"]))

    print(f"\n{C_B}{'STUDENT':<31}{'LAB':<14}{'PROJECT':<11}{'APPS':>5}  "
          f"STAGING SERVICES{C_Z}")
    print("─" * 88)
    prev = None
    for r in rows:
        key = (r["lab_done"], r["mig"])
        if prev is not None and key != prev:
            print()
        prev = key
        name = r["team"].replace("'s Sandbox", "")[:30]
        lab_c = C_OK if r["lab_done"] else C_WARN
        mig_c = MIG_COLOUR[r["mig"]]
        app_c = "" if r["napps"] == 2 else C_WARN
        svcs = ", ".join(sorted(r["svcs"])) if r["svcs"] else ""
        if len(svcs) > 30:
            svcs = svcs[:29] + "…"
        print(f"{name:<31}{lab_c}{r['lab']:<14}{C_Z}{mig_c}{r['mig']:<11}{C_Z}"
              f"{app_c}{r['napps']:>5}{C_Z}  {C_DIM}{svcs}{C_Z}")

    print("─" * 88)
    counts = {}
    for r in rows:
        counts[r["mig"]] = counts.get(r["mig"], 0) + 1
    print(f"{len(rows)} students — step 13 progress")
    blurb = {
        "migrated":  "own services on both branches",
        "staging":   "own services on staging, main still template",
        "main only": "own services on main but not staging — out of order",
        "template":  "still the stock hello/time/db template",
        "no repo":   "no readable docker-compose.yaml",
    }
    for _, lab, c in MIGRATION[::-1]:
        if counts.get(lab):
            print(f"  {counts[lab]:>3} {c}{lab:<11}{C_Z}{C_DIM}{blurb[lab]}{C_Z}")
    not_through = [r for r in rows if not r["lab_done"]]
    if not_through:
        print(f"\n{C_WARN}{len(not_through)} have not finished the lab yet{C_Z}"
              f"{C_DIM} — they cannot start step 13{C_Z}")
    odd = [r for r in rows if r["napps"] != 2]
    if odd:
        print(f"{C_WARN}{len(odd)} with an application count other than 2{C_Z}"
              f"{C_DIM} — stray or duplicate apps{C_Z}")
        for r in odd:
            print(f"      {r['team'].replace(chr(39)+'s Sandbox',''):<28}"
                  f"{r['napps']} apps")


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
    ap.add_argument("--all", action="store_true",
                    help="list every student as a row, including LIVE and not-started")
    ap.add_argument("--project", action="store_true",
                    help="step 13 view: has each student replaced the template "
                         "with their own project?")
    args = ap.parse_args()

    apps = fetch_apps()
    if not apps:
        print("No data from Coolify. On the CS VPN? ssh to the Coolify host working?")
        sys.exit(1)
    running = containers()
    if args.student:
        deep_dive(args.student, apps, running)
    elif args.project:
        project_view(apps, running)
    else:
        overview(apps, running, show_all=args.all)


if __name__ == "__main__":
    main()
