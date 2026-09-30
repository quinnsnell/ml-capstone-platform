#!/usr/bin/env python3
"""
prelab-check.py — the "did the pre-lab setup work?" Canvas survey.

Students do the pre-lab steps (accept the org invite, create their repo from
the template, check Docker, clone + run it locally) and then report how it went
here. The point is to find broken laptops the night before the lab rather than
with thirty people watching.

    create    Create + publish the survey in Canvas
    status    Who has reported, who is stuck, and on what

Credentials come from .env, same as canvas-roster.py.
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("cr", os.path.join(HERE, "canvas-roster.py"))
cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cr)

TITLE = "Pre-Lab Setup Check"

# Where students actually get stuck, in the order the pre-lab email walks them.
# Keeping these as distinct options is the whole value: "it didn't work" in a
# free-text box costs a conversation, whereas "docker compose build failed" is
# already triaged.
STUCK_OPTIONS = [
    "Nothing — it all worked",
    "Accepting the GitHub organization invitation",
    "Creating my repository from the template",
    "Docker — wrong version, or it won't install",
    "git clone",
    "git checkout -B staging main / git push",
    "docker compose up — the build failed",
    "docker compose up — it started, but containers are not healthy",
    "./smoke-test.sh failed",
    "Connecting to the CS VPN",
    "Something else (describe below)",
]

QUESTIONS = [
    {
        "name": "Outcome",
        "type": "multiple_choice_question",
        "text": "<p><strong>How did the pre-lab setup go?</strong></p>",
        "answers": [
            "Everything worked — ./smoke-test.sh passed",
            "The app runs, but ./smoke-test.sh failed",
            "I got stuck before that",
            "I haven't started yet",
        ],
    },
    {
        "name": "Stuck where",
        "type": "multiple_choice_question",
        "text": (
            "<p><strong>If you got stuck, where?</strong></p>"
            "<p>Pick the first thing that failed, even if later steps also failed "
            "because of it.</p>"
        ),
        "answers": STUCK_OPTIONS,
    },
    {
        "name": "Repo name",
        "type": "essay_question",
        "text": (
            "<p><strong>What is your repository name?</strong></p>"
            "<p>Just the name, e.g. <code>alice-hello</code> — not the full URL. "
            "This lets me look at your repo directly instead of asking you to "
            "describe it.</p>"
        ),
    },
    {
        "name": "What happened",
        "type": "essay_question",
        "text": (
            "<p><strong>If something failed, what did you see?</strong></p>"
            "<p>Paste the actual error message if you have one — the exact text is "
            "far more useful than a description of it. If everything worked, just "
            "write <code>none</code>.</p>"
        ),
    },
]


def build_quiz(cv, draft=False, force=False):
    existing = [q for q in cv.get_paginated(f"/courses/{cv.course}/quizzes")
                if q.get("title") == TITLE]
    if existing and not force:
        q = existing[0]
        print(f"A quiz titled {TITLE!r} already exists (id {q['id']}).")
        print(f"  {q.get('html_url')}")
        print("Re-run with --force to create another.")
        return

    quiz = cv.post(
        f"/courses/{cv.course}/quizzes",
        {
            "quiz[title]": TITLE,
            "quiz[description]": (
                "<p>Report how the pre-lab setup went — whether it worked or you got "
                "stuck. Take this as soon as you finish, or as soon as you hit "
                "something you cannot get past.</p>"
                "<p>Do not spend an hour fighting a problem before telling me. If you "
                "are stuck, say so here and I will help before the lab.</p>"
                "<p>You can retake this as many times as you like — only your latest "
                "answers count, so come back and update it once you are unstuck.</p>"
            ),
            "quiz[quiz_type]": "survey",
            "quiz[anonymous_submissions]": "false",
            "quiz[allowed_attempts]": -1,
            "quiz[scoring_policy]": "keep_latest",
            "quiz[published]": "false",
        },
    )
    qid = quiz["id"]
    print(f"Created quiz {qid}: {TITLE}")

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

    if draft:
        print("\nLeft UNPUBLISHED. Review it, then publish from the Canvas UI:")
    else:
        cv._request("PUT", f"/courses/{cv.course}/quizzes/{qid}",
                    data={"quiz[published]": "true"})
        print("\nPublished. Send students here:")
    print(f"  {quiz.get('html_url')}")


def cmd_create(args):
    build_quiz(cr.canvas_from_env(), draft=args.draft, force=args.force)


def cmd_status(args):
    cv = cr.canvas_from_env()
    quiz = cr.find_quiz(cv, TITLE)
    rows = cr.fetch_responses(cv, quiz["id"])
    qids = cr.quiz_question_ids(cv, quiz["id"])
    if not rows:
        print("No responses yet.")
        return

    cols = list(rows[0].keys())
    col = {k: cr.column_for(cols, k, qids.get(n))
           for k, n in (("outcome", "Outcome"), ("stuck", "Stuck where"),
                        ("repo", "Repo name"), ("what", "What happened"))}

    students = {str(s["id"]): re.sub(r"\s+", " ", s.get("name") or "").strip()
                for s in cv.students()}
    seen, outcomes, stuck_tally, problems = {}, collections.Counter(), collections.Counter(), []

    for r in rows:
        uid = (r.get("id") or "").strip()
        if not uid:
            continue
        get = lambda k: (r.get(col[k]) or "").strip() if col[k] else ""
        seen[uid] = True
        outcome, stuck = get("outcome"), get("stuck")
        outcomes[outcome or "(blank)"] += 1
        if stuck and not stuck.startswith("Nothing"):
            stuck_tally[stuck] += 1
        if outcome and not outcome.startswith("Everything worked"):
            problems.append((students.get(uid, r.get("name", "?")), outcome,
                             stuck, get("repo"), get("what")))

    total = len(students)
    print(f"{len(seen)}/{total} students have reported.\n")
    print("OUTCOMES")
    for k, n in outcomes.most_common():
        print(f"  {n:2}  {k}")

    if stuck_tally:
        print("\nWHERE PEOPLE ARE STUCK")
        for k, n in stuck_tally.most_common():
            print(f"  {n:2}  {k}")

    if problems:
        print("\nNEEDS HELP")
        for name, outcome, stuck, repo, what in sorted(problems):
            print(f"\n  {name}   [{repo or 'no repo given'}]")
            print(f"    outcome: {outcome}")
            if stuck and not stuck.startswith("Nothing"):
                print(f"    stuck:   {stuck}")
            if what and what.lower() not in ("none", "n/a", "-"):
                print(f"    said:    {what[:300]}")

    missing = [n for uid, n in students.items() if uid not in seen]
    if missing:
        print(f"\nNOT YET REPORTED ({len(missing)})")
        for n in sorted(missing):
            print(f"  {n}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("create", help="create the survey in Canvas")
    p.add_argument("--draft", action="store_true", help="leave unpublished for review")
    p.add_argument("--force", action="store_true", help="create even if the title exists")
    p.set_defaults(func=cmd_create)
    p = sub.add_parser("status", help="who reported, who is stuck")
    p.set_defaults(func=cmd_status)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
