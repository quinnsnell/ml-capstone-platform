#!/usr/bin/env bash
# =============================================================================
# term-start.sh — run the whole term-start provisioning sequence in order
#
# Wraps the five scripts that have to happen in a specific order, enforces the
# preconditions between them, and refuses to continue when one is unmet. It adds
# no provisioning logic of its own: every phase shells out to the script that
# already owns that job, so anything this does can also be done by hand.
#
#   1. roster    canvas-roster.py build      Canvas + survey -> roster CSV
#   2. invite    invite-to-org.sh            GitHub org invitations
#   -  GATE      students must ACCEPT those invitations
#   3. teams     provision-gh-teams.sh       GitHub Teams + membership
#   4. coolify   provision-teams.sh          Coolify teams/users/server (on rigel)
#   5. verify    verify-provisioning.sh      read-only check of all of the above
#
# WHY THIS IS NOT ONE FIRE-AND-FORGET RUN. Phase 3 cannot add a student to a
# GitHub Team until they have accepted the org invitation from phase 2, and that
# wait is measured in days. Run phases 1-2, chase the stragglers, then come back
# and run 3-5. The gate between them exists so a half-accepted roster fails
# loudly instead of silently provisioning a subset of the class.
#
# SAFETY. Preview is the default, matching the underlying scripts: without
# --apply every phase runs in its own dry-run mode and changes nothing. Each
# phase is independently idempotent, so re-running after a fix is always safe.
#
# Usage:
#   ./term-start.sh                                   # preview everything
#   ./term-start.sh --apply                           # execute
#   ./term-start.sh --only roster                     # one phase
#   ./term-start.sh --from teams --apply              # resume after the gate
#   ./term-start.sh --term 2026-fall --apply
#
# Options:
#   --term NAME        Term label for the roster filename (default: current)
#   --roster PATH      Use this roster instead of building//picking one
#   --org NAME         GitHub org (default: byu-ml-capstone)
#   --rigel-host HOST  ssh target for the Coolify phase (default: rigel)
#   --only PHASE       Run a single phase: roster|invite|teams|coolify|verify
#   --from PHASE       Start at PHASE and run everything after it
#   --skip-gate        Proceed past the acceptance gate even if some are pending
#   --apply            Actually make changes (default is preview)
#   -h, --help         This message
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

TERM_NAME=current
ROSTER=""
ORG=byu-ml-capstone
RIGEL_HOST=rigel
ONLY=""
FROM=""
SKIP_GATE=0
APPLY=0

PHASES=(roster invite teams coolify verify)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --term)        TERM_NAME="$2"; shift 2 ;;
        --roster)      ROSTER="$2";    shift 2 ;;
        --org)         ORG="$2";       shift 2 ;;
        --rigel-host)  RIGEL_HOST="$2";shift 2 ;;
        --only)        ONLY="$2";      shift 2 ;;
        --from)        FROM="$2";      shift 2 ;;
        --skip-gate)   SKIP_GATE=1;    shift ;;
        --apply)       APPLY=1;        shift ;;
        -h|--help)     sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; echo "Run with --help." >&2; exit 1 ;;
    esac
done

C_B=$'\033[1m'; C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_Z=$'\033[0m'
[[ -t 1 ]] || { C_B=""; C_G=""; C_R=""; C_Y=""; C_D=""; C_Z=""; }

banner() { printf '\n%s%s %s %s%s\n' "$C_B" "$(printf '=%.0s' {1..12})" "$1" "$(printf '=%.0s' {1..12})" "$C_Z"; }
info()   { printf '%s%s%s\n' "$C_D" "$1" "$C_Z"; }
good()   { printf '%s%s%s\n' "$C_G" "$1" "$C_Z"; }
warn()   { printf '%s%s%s\n' "$C_Y" "$1" "$C_Z"; }
fail()   { printf '%s%s%s\n' "$C_R" "$1" "$C_Z" >&2; exit 1; }

should_run() {
    local phase="$1"
    [[ -n "$ONLY" ]] && { [[ "$phase" == "$ONLY" ]] && return 0 || return 1; }
    if [[ -n "$FROM" ]]; then
        local seen=0
        for p in "${PHASES[@]}"; do
            [[ "$p" == "$FROM" ]] && seen=1
            [[ "$p" == "$phase" ]] && { (( seen )) && return 0 || return 1; }
        done
        return 1
    fi
    return 0
}

validate_phase_name() {
    local given="$1" label="$2"
    [[ -z "$given" ]] && return 0
    for p in "${PHASES[@]}"; do [[ "$p" == "$given" ]] && return 0; done
    fail "$label: unknown phase '$given'. Valid: ${PHASES[*]}"
}
validate_phase_name "$ONLY" "--only"
validate_phase_name "$FROM" "--from"

# Underlying scripts all default to preview and take --apply to execute.
APPLY_FLAG=()
(( APPLY )) && APPLY_FLAG=(--apply)

pick_roster() {
    [[ -n "$ROSTER" ]] && { echo "$ROSTER"; return; }
    local newest
    newest=$(ls -1t "$REPO_ROOT"/roster-*.csv 2>/dev/null | grep -v 'roster-example.csv' | head -n1 || true)
    echo "$newest"
}

# ---- Preflight -----------------------------------------------------------
banner "PREFLIGHT"
if (( APPLY )); then
    warn "APPLY mode — this will make real changes to GitHub and Coolify."
else
    info "Preview mode. Nothing will be changed. Re-run with --apply to execute."
fi

command -v gh >/dev/null || fail "gh CLI not found — needed for the GitHub phases."
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated. Run: gh auth login"
info "gh authenticated as: $(gh api /user --jq .login 2>/dev/null || echo '?')"
gh api "/orgs/$ORG" >/dev/null 2>&1 || fail "cannot read org '$ORG' — are you an Owner?"
good "org $ORG reachable"

# ---- Phase 1: roster -----------------------------------------------------
if should_run roster; then
    banner "PHASE 1/5 — roster"
    if [[ -n "$ROSTER" ]]; then
        info "Using the roster passed on the command line; not rebuilding."
        [[ -f "$ROSTER" ]] || fail "roster not found: $ROSTER"
    else
        info "Building the roster from Canvas + survey responses."
        args=(build --term "$TERM_NAME" --verify-github)
        (( APPLY )) || info "(preview: canvas-roster.py build is read-only apart from writing the CSV)"
        "$SCRIPT_DIR/canvas-roster.py" "${args[@]}" \
            || fail "roster build failed — fix the reported problems and re-run --only roster"
    fi
fi

ROSTER="$(pick_roster)"
[[ -n "$ROSTER" && -f "$ROSTER" ]] || fail "no roster CSV found. Run: ./scripts/term-start.sh --only roster"
ROSTER_COUNT=$(python3 -c "
import csv,sys
rows=[r for r in csv.DictReader(open('$ROSTER')) if (r.get('github_username') or '').strip() and not (r.get('team_name') or '').startswith('#')]
print(len(rows))")
good "roster: $ROSTER ($ROSTER_COUNT students)"

# ---- Phase 2: GitHub org invitations ------------------------------------
if should_run invite; then
    banner "PHASE 2/5 — GitHub org invitations"
    "$SCRIPT_DIR/invite-to-org.sh" --roster "$ROSTER" --org "$ORG" "${APPLY_FLAG[@]}" \
        || fail "invite-to-org.sh failed"
fi

# ---- GATE: invitations must be accepted ---------------------------------
gate_acceptance() {
    banner "GATE — org invitation acceptance"
    info "A student cannot be added to a GitHub Team until they accept the org invite."
    local pending=() total=0
    while IFS= read -r user; do
        [[ -z "$user" ]] && continue
        total=$((total+1))
        # gh prints its error body to STDOUT on 404, so a bare substitution would
        # capture the JSON. Assign, then overwrite on non-zero exit.
        local state
        state=$(gh api "/orgs/$ORG/memberships/$user" --jq .state 2>/dev/null) || state=""
        case "$state" in
            active)  ;;
            pending) pending+=("$user — invited, not yet accepted") ;;
            *)       pending+=("$user — no invitation found (bad username?)") ;;
        esac
    done < <(python3 -c "
import csv
seen=set()
for r in csv.DictReader(open('$ROSTER')):
    u=(r.get('github_username') or '').strip()
    if u and not (r.get('team_name') or '').startswith('#') and u not in seen:
        seen.add(u); print(u)")

    if (( ${#pending[@]} == 0 )); then
        good "all $total students have accepted — safe to continue"
        return 0
    fi

    warn "${#pending[@]} of $total students have NOT accepted their invitation:"
    printf '  %s\n' "${pending[@]}"
    if (( SKIP_GATE )); then
        warn "--skip-gate given: continuing anyway. Students above will be missing from"
        warn "their GitHub Team; re-run '--from teams --apply' once they accept."
        return 0
    fi
    echo
    info "Chase them, then re-run:  ./scripts/term-start.sh --from teams${APPLY:+ --apply}"
    info "Or pass --skip-gate to provision everyone else now (safe: re-running fills the gaps)."
    exit 2
}
if should_run teams || should_run coolify; then
    gate_acceptance
fi

# ---- Phase 3: GitHub Teams ----------------------------------------------
if should_run teams; then
    banner "PHASE 3/5 — GitHub Teams"
    "$SCRIPT_DIR/provision-gh-teams.sh" --roster "$ROSTER" --org "$ORG" "${APPLY_FLAG[@]}" \
        || fail "provision-gh-teams.sh failed"
fi

# ---- Phase 4: Coolify (runs on rigel) -----------------------------------
if should_run coolify; then
    banner "PHASE 4/5 — Coolify teams, users, server, destination"
    if [[ -f /etc/qwen-cluster/pinned-state.conf ]] || [[ "$(hostname -s)" == "$RIGEL_HOST" ]]; then
        LOCAL_RIGEL=1
    else
        LOCAL_RIGEL=0
    fi

    if (( LOCAL_RIGEL )); then
        info "Running locally (this host looks like the Coolify host)."
        "$SCRIPT_DIR/provision-teams.sh" --check-schema || fail "Coolify schema check failed — do NOT proceed"
        "$SCRIPT_DIR/provision-teams.sh" --roster "$ROSTER" "${APPLY_FLAG[@]}" \
            || fail "provision-teams.sh failed"
    else
        info "provision-teams.sh needs docker access to coolify-db, so it runs on $RIGEL_HOST."
        ssh -o BatchMode=yes "$RIGEL_HOST" true 2>/dev/null \
            || fail "cannot ssh to $RIGEL_HOST non-interactively. Run phase 4 there by hand, or fix ssh keys."
        info "Copying the roster to $RIGEL_HOST (contains student PII — it is gitignored on both ends)."
        (( APPLY )) && scp -q "$ROSTER" "$RIGEL_HOST:~/ml-capstone-platform/$(basename "$ROSTER")"
        # Schema drift after a Coolify auto-upgrade would emit broken INSERTs.
        ssh "$RIGEL_HOST" "cd ~/ml-capstone-platform && ./scripts/provision-teams.sh --check-schema" \
            || fail "Coolify schema check failed on $RIGEL_HOST — do NOT proceed; see onboarding.md step 3a"
        ssh "$RIGEL_HOST" "cd ~/ml-capstone-platform && ./scripts/provision-teams.sh --roster '$(basename "$ROSTER")' ${APPLY_FLAG[*]}" \
            || fail "provision-teams.sh failed on $RIGEL_HOST"
    fi
fi

# ---- Phase 5: verify -----------------------------------------------------
if should_run verify; then
    banner "PHASE 5/5 — verify"
    if (( APPLY )); then
        "$SCRIPT_DIR/verify-provisioning.sh" --roster "$ROSTER" || fail "verification found problems"
        good "verification passed"
    else
        info "Skipped in preview mode — there is nothing provisioned yet to verify."
    fi
fi

banner "DONE"
if (( APPLY )); then
    good "Term-start provisioning complete for $ROSTER_COUNT students."
    cat <<EOF

Still to do by hand:
  - Students follow student-guide.md Part B to create their own Applications.
  - CS VPN access for anyone who reported a problem (canvas-roster.py status).
  - ./scripts/smoke-test-cluster.sh   to confirm the cluster itself is healthy.
EOF
else
    info "Preview complete. Re-run with --apply to execute."
fi
