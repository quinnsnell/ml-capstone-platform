#!/usr/bin/env python3
"""
canvas-roster.py — build the class roster CSV from Canvas + a student survey.

Canvas knows each student's name and email. It does NOT know their GitHub
username, which every provisioning script needs. This collects that with a
Canvas survey and merges the answers back into the roster CSV that
invite-to-org.sh / provision-gh-teams.sh / provision-teams.sh all read.

    create-quiz   Create + publish the onboarding survey in Canvas
    status        Who has responded, who hasn't (chase list)
    build         Merge Canvas roster + responses -> roster-<term>.csv

Typical term start:

    ./scripts/canvas-roster.py create-quiz
    # ... point students at it, wait ...
    ./scripts/canvas-roster.py status
    ./scripts/canvas-roster.py build --term 2026-fall --verify-github

Credentials come from .env in the repo root (gitignored):

    CANVAS_HOST=byu.instructure.com
    CANVAS_COURSE=12345
    CANVAS_TOKEN=...

The output CSV contains real student emails and is matched by .gitignore's
`roster-*.csv` rule. Never commit it (FERPA).
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The survey. Free-text answers use essay_question: Canvas's
# "short_answer_question" is a fill-in-the-blank that auto-grades against a
# stored correct answer, which is not what we want.
QUESTIONS = [
    {
        "name": "GitHub username",
        "type": "essay_question",
        "text": (
            "<p>What is your <strong>GitHub username</strong>?</p>"
            "<p>Just the username, not the full URL &mdash; if your profile is "
            "<code>https://github.com/octocat</code>, answer <code>octocat</code>.</p>"
            "<p>You need a GitHub account for this course. If you don't have one, "
            "create it at <a href='https://github.com/join'>github.com/join</a> first. "
            "A typo here means your org invitation goes nowhere, so double-check it.</p>"
        ),
        "key": "github_username",
    },
    {
        "name": "GitHub email",
        "type": "essay_question",
        "text": (
            "<p>What <strong>email address</strong> is on your GitHub account?</p>"
            "<p>If it's the same BYU address Canvas has for you, just answer "
            "<code>same</code>. Otherwise give the address you actually sign in with "
            "&mdash; Coolify matches your login against this, so a mismatch locks you "
            "out of the deployment platform.</p>"
        ),
        "key": "github_email",
    },
    {
        "name": "CS VPN access",
        "type": "multiple_choice_question",
        "text": (
            "<p>Can you connect to the <strong>CS VPN</strong>?</p>"
            "<p>This is <code>cs-vpn.byu.edu</code> in GlobalProtect &mdash; NOT the "
            "campus <code>vpn.byu.edu</code> gateway. They are different networks and "
            "only the CS one reaches the class cluster.</p>"
            "<p>Connect, then run this in a terminal:</p>"
            "<pre>curl -sS http://ml-capstone.cs.byu.edu:4000/v1/models</pre>"
            "<p>It should print JSON mentioning <code>classroom-chat</code>.</p>"
        ),
        "key": "vpn_ok",
        "answers": [
            "Yes — I connected and got the JSON back",
            "I can connect to the CS VPN, but the command failed",
            "No — cs-vpn.byu.edu rejects me or isn't listed in GlobalProtect",
            "I haven't tried yet",
        ],
    },
]


# --------------------------------------------------------------------------
# Canvas API
# --------------------------------------------------------------------------
class Canvas:
    def __init__(self, host: str, token: str, course: str):
        self.base = f"https://{host.strip().rstrip('/')}/api/v1"
        self.token = token
        self.course = str(course).strip()

    def _request(self, method, path, data=None, absolute=False):
        url = path if absolute else f"{self.base}{path}"
        body = None
        headers = {"Authorization": f"Bearer {self.token}"}
        if data is not None:
            body = urllib.parse.urlencode(data, doseq=True).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req) as resp:
                return json.loads(resp.read().decode() or "null"), resp.headers
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:400]
            die(f"Canvas {method} {url} -> HTTP {e.code}\n  {detail}")

    def get(self, path, **params):
        qs = urllib.parse.urlencode(params, doseq=True)
        payload, _ = self._request("GET", f"{path}?{qs}" if qs else path)
        return payload

    def get_paginated(self, path, **params):
        """Canvas paginates via RFC 5988 Link headers; follow rel="next"."""
        params.setdefault("per_page", 100)
        url = f"{self.base}{path}?{urllib.parse.urlencode(params, doseq=True)}"
        out = []
        while url:
            payload, headers = self._request("GET", url, absolute=True)
            out.extend(payload)
            url = None
            for part in (headers.get("Link") or "").split(","):
                if 'rel="next"' in part:
                    url = part.split(";")[0].strip().strip("<>")
        return out

    def post(self, path, data):
        payload, _ = self._request("POST", path, data=data)
        return payload

    def students(self):
        rows = self.get_paginated(
            f"/courses/{self.course}/users",
            **{
                "enrollment_type[]": "student",
                "enrollment_state[]": "active",
                "include[]": "email",
            },
        )
        # Deduplicate: a student enrolled in multiple sections appears twice.
        seen, students = set(), []
        for u in rows:
            if u["id"] in seen:
                continue
            seen.add(u["id"])
            students.append(u)
        return students


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def load_env():
    path = os.path.join(REPO_ROOT, ".env")
    if not os.path.exists(path):
        die(f"no .env at {path}")
    env = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    missing = [k for k in ("CANVAS_HOST", "CANVAS_COURSE", "CANVAS_TOKEN") if not env.get(k)]
    if missing:
        die(f".env is missing: {', '.join(missing)}")
    return env


def canvas_from_env():
    env = load_env()
    return Canvas(env["CANVAS_HOST"], env["CANVAS_TOKEN"], env["CANVAS_COURSE"])


# --------------------------------------------------------------------------
# create-quiz
# --------------------------------------------------------------------------
def cmd_create_quiz(args):
    cv = canvas_from_env()

    existing = [q for q in cv.get_paginated(f"/courses/{cv.course}/quizzes")
                if q.get("title") == args.title]
    if existing and not args.force:
        q = existing[0]
        print(f"A quiz titled {args.title!r} already exists (id {q['id']}).")
        print(f"  {q.get('html_url')}")
        print("Re-run with --force to create another, or just use this one.")
        return

    # anonymous_submissions MUST stay false: an anonymous survey cannot be
    # joined back to a student, which is the entire point of this exercise.
    quiz = cv.post(
        f"/courses/{cv.course}/quizzes",
        {
            "quiz[title]": args.title,
            "quiz[description]": (
                "<p>Two minutes of setup information so your instructor can provision "
                "your accounts on the class cluster.</p>"
                "<p>You can retake this as many times as you like &mdash; only your "
                "latest answers are used, so come back and fix a typo if you spot one.</p>"
            ),
            "quiz[quiz_type]": "survey",
            "quiz[anonymous_submissions]": "false",
            "quiz[allowed_attempts]": -1,
            "quiz[scoring_policy]": "keep_latest",
            "quiz[published]": "false",
        },
    )
    qid = quiz["id"]
    print(f"Created quiz {qid}: {args.title}")

    for position, q in enumerate(QUESTIONS, start=1):
        data = {
            "question[question_name]": q["name"],
            "question[question_text]": q["text"],
            "question[question_type]": q["type"],
            "question[points_possible]": 0,
            "question[position]": position,
        }
        for i, ans in enumerate(q.get("answers", [])):
            data[f"question[answers][{i}][answer_text]"] = ans
            data[f"question[answers][{i}][answer_weight]"] = 100 if i == 0 else 0
        cv.post(f"/courses/{cv.course}/quizzes/{qid}/questions", data)
        print(f"  + {q['name']}")

    cv._request("PUT", f"/courses/{cv.course}/quizzes/{qid}",
                data={"quiz[published]": "true"})
    print("\nPublished. Send students here:")
    print(f"  {quiz.get('html_url')}")


# --------------------------------------------------------------------------
# Reading responses (student_analysis report -> CSV)
# --------------------------------------------------------------------------
def find_quiz(cv, title):
    for q in cv.get_paginated(f"/courses/{cv.course}/quizzes"):
        if q.get("title") == title:
            return q
    die(f"no quiz titled {title!r} in course {cv.course}. Run create-quiz first.")


def fetch_responses(cv, quiz_id):
    """Generate a student_analysis report and return its parsed CSV rows."""
    try:
        report = cv.post(
            f"/courses/{cv.course}/quizzes/{quiz_id}/reports",
            {"quiz_report[report_type]": "student_analysis",
             "include[]": "file"},
        )
    except SystemExit:
        # 409 means one is already generating; fall back to the existing report.
        reports = cv.get(f"/courses/{cv.course}/quizzes/{quiz_id}/reports",
                         **{"includes_all_versions": "false"})
        report = next((r for r in reports if r.get("report_type") == "student_analysis"), None)
        if not report:
            die("could not obtain a student_analysis report")

    for _ in range(60):
        detail = cv.get(f"/courses/{cv.course}/quizzes/{quiz_id}/reports/{report['id']}",
                        **{"include[]": "file"})
        f = detail.get("file") or {}
        if f.get("url"):
            with urllib.request.urlopen(f["url"]) as resp:
                text = resp.read().decode("utf-8-sig", errors="replace")
            return list(csv.DictReader(io.StringIO(text)))
        time.sleep(2)
    die("timed out waiting for Canvas to generate the report")


def column_for(fieldnames, needle):
    """Report columns are '<question id>: <question text>'. Match on text."""
    for name in fieldnames:
        if needle.lower() in (name or "").lower():
            return name
    return None


def parse_responses(rows):
    """-> {canvas_user_id: {github_username, github_email, vpn_ok}}"""
    if not rows:
        return {}
    cols = list(rows[0].keys())
    col_user = column_for(cols, "GitHub username") or column_for(cols, "username")
    col_mail = column_for(cols, "GitHub email") or column_for(cols, "email")
    col_vpn = column_for(cols, "CS VPN") or column_for(cols, "vpn")

    out = {}
    for row in rows:
        uid = (row.get("id") or "").strip()
        if not uid:
            continue
        gh = clean_username(row.get(col_user, "") if col_user else "")
        out[uid] = {
            "github_username": gh,
            "github_email": (row.get(col_mail, "") if col_mail else "").strip(),
            "vpn_ok": (row.get(col_vpn, "") if col_vpn else "").strip(),
            "name": (row.get("name") or "").strip(),
        }
    return out


def clean_username(raw):
    """Students paste URLs, @handles, and trailing whitespace. Normalise."""
    s = (raw or "").strip()
    if not s:
        return ""
    s = re.sub(r"^https?://(www\.)?github\.com/", "", s, flags=re.I)
    s = s.split("/")[0].split("?")[0].lstrip("@").strip()
    return s


GITHUB_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$")


def github_exists(username):
    """True/False/None (None = couldn't check)."""
    try:
        r = subprocess.run(["gh", "api", f"/users/{username}"],
                           capture_output=True, text=True, timeout=20)
        if r.returncode == 0:
            return True
        if "Not Found" in (r.stderr or ""):
            return False
        return None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------
def cmd_status(args):
    cv = canvas_from_env()
    quiz = find_quiz(cv, args.title)
    students = cv.students()
    answers = parse_responses(fetch_responses(cv, quiz["id"]))

    done, missing = [], []
    for s in students:
        rec = answers.get(str(s["id"]))
        (done if rec and rec.get("github_username") else missing).append(s)

    print(f"{len(done)}/{len(students)} students have submitted a usable response.\n")
    if missing:
        print("Still waiting on:")
        for s in sorted(missing, key=lambda u: u.get("sortable_name") or u["name"]):
            print(f"  {s.get('name'):<28} {s.get('email') or s.get('login_id') or ''}")
    else:
        print("Everyone has responded — ready to run: build")

    flagged = [(s, answers[str(s['id'])]) for s in students
               if str(s["id"]) in answers
               and answers[str(s['id'])].get("vpn_ok", "").lower().startswith(("no", "i can connect"))]
    if flagged:
        print("\nVPN problems reported — these need CS VPN access sorted out:")
        for s, rec in flagged:
            print(f"  {s.get('name'):<28} {rec['vpn_ok']}")


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------
def cmd_build(args):
    cv = canvas_from_env()
    quiz = find_quiz(cv, args.title)
    students = cv.students()
    answers = parse_responses(fetch_responses(cv, quiz["id"]))

    rows, skipped, warnings = [], [], []
    used_teams = {}

    for s in sorted(students, key=lambda u: u.get("sortable_name") or u.get("name") or ""):
        uid = str(s["id"])
        name = (s.get("name") or "").strip()
        canvas_email = (s.get("email") or s.get("login_id") or "").strip()
        rec = answers.get(uid)

        if not rec or not rec.get("github_username"):
            skipped.append((name, canvas_email, "no survey response"))
            continue

        gh = rec["github_username"]
        if not GITHUB_RE.match(gh):
            skipped.append((name, canvas_email, f"implausible GitHub username {gh!r}"))
            continue

        # Coolify matches on the email the student signs in to GitHub with.
        stated = rec.get("github_email", "")
        email = canvas_email
        if stated and stated.lower() not in ("same", "same as canvas", "n/a", "-"):
            if "@" in stated:
                email = stated
                if stated.lower() != canvas_email.lower():
                    warnings.append(f"{name}: GitHub email {stated} differs from Canvas {canvas_email}")

        team = args.team_template.format(name=name, first=name.split()[0] if name else gh, github=gh)
        if team in used_teams:
            team = f"{team} ({gh})"   # two students sharing a first name
        used_teams[team] = True

        rows.append({"team_name": team, "email": email,
                     "name": name, "github_username": gh})

    if args.verify_github:
        print("Verifying GitHub usernames resolve...", file=sys.stderr)
        for r in rows:
            exists = github_exists(r["github_username"])
            if exists is False:
                warnings.append(f"{r['name']}: GitHub user {r['github_username']!r} does not exist")
            elif exists is None:
                warnings.append(f"{r['name']}: could not verify {r['github_username']!r} (is `gh` authenticated?)")

    out = args.out or os.path.join(REPO_ROOT, f"roster-{args.term}.csv")
    with open(out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["team_name", "email", "name", "github_username"])
        w.writeheader()
        w.writerows(rows)

    print(f"\nWrote {len(rows)} rows to {out}")
    if warnings:
        print(f"\n{len(warnings)} warning(s) — fix these before provisioning:")
        for wmsg in warnings:
            print(f"  ! {wmsg}")
    if skipped:
        print(f"\n{len(skipped)} student(s) NOT in the roster:")
        for name, email, why in skipped:
            print(f"  - {name:<28} {email:<32} {why}")
        print("\nChase them, then re-run build — it is safe to regenerate.")
    print("\nThis file contains real student data. It is gitignored; keep it that way.")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--title", default="Class Cluster Setup",
                    help="Canvas quiz title (default: %(default)s)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("create-quiz", help="create + publish the survey in Canvas")
    p.add_argument("--force", action="store_true", help="create even if the title exists")
    p.set_defaults(func=cmd_create_quiz)

    p = sub.add_parser("status", help="who has responded, who hasn't")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("build", help="write roster-<term>.csv")
    p.add_argument("--term", default="current", help="used in the filename")
    p.add_argument("--out", help="explicit output path")
    p.add_argument("--team-template", default="{first}'s Sandbox",
                   help="team_name pattern; {name} {first} {github} (default: %(default)s)")
    p.add_argument("--verify-github", action="store_true",
                   help="check each username exists via the gh CLI")
    p.set_defaults(func=cmd_build)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
