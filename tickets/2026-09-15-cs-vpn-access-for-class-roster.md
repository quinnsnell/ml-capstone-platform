# CS VPN access for the ML capstone class roster

**Status: DRAFT — not yet sent.** Verify the right recipient and the actual CS process before sending; adjust the ask to match. Once sent and resolved, record the real mechanism in [`../onboarding.md`](../onboarding.md) → *Term-start: request CS VPN access for the roster* and move this file to `archive/`.

Per the conventions in [`README.md`](README.md): one ask per ticket, be specific, and lead with the concrete request.

---

Hi,

I'm teaching the ML capstone course this term. The class uses a GPU cluster on the CS network (`rigel`, `castor`, `pollux`) that students reach over the **CS VPN** — the class LLM endpoint and every student-deployed app are VPN-only by design. Nothing about the class is exposed to the public internet beyond the GitHub webhook path you already set up for us via HAProxy.

## What I need

CS VPN access (`cs-vpn.byu.edu`) for the enrolled students in the course. I can provide the roster in whatever form is easiest — NetIDs in a list, a CSV, or a course/section number you can pull enrollment from.

- **Course:** <COURSE NUMBER + SECTION>
- **Term:** <TERM>
- **Headcount:** roughly <N> students
- **Duration needed:** through the end of the term (happy to have it expire automatically)

A few students are not CS majors and may not have a CS account at all — please let me know if those need a separate or prior step, since they're the ones most likely to fall through.

## Questions so I can document the process

We keep an instructor runbook so this doesn't get rediscovered every term. Could you confirm:

1. **Who submits, and how?** This ticket queue, or a different form/process?
2. **Roster-based or per-student?** Can I hand you one list at term start, or does each student have to request individually?
3. **What does it key off?** A CS account, a group membership, enrollment, something else?
4. **Turnaround?** So I know how far before the first class meeting to submit.
5. **Late adds** — what's the fastest path for a student who joins in week two?
6. **Expiry/revocation** — does it lapse automatically at term end, or should I send a revocation list?

## Why this matters for the class

Students who are on the **campus** VPN (`vpn.byu.edu`) but not the **CS** VPN see a confusing failure: GlobalProtect reports "Connected," but every class hostname fails to resolve and every request hangs. It reads like a broken editor configuration rather than an access problem, so it costs a full lab session to diagnose. Getting the roster provisioned before day one avoids that entirely.

Thanks!
— Quinn
