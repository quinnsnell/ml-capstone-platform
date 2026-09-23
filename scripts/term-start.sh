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
#   ./term-start.sh --only gate                       # who hasn't accepted yet?
#   ./term-start.sh --only roster                     # one phase
#   ./term-start.sh --from teams --apply              # resume after the gate
#   ./term-start.sh --term 2026-fall --apply
#
# Options:
#   --term NAME        Term label for the roster filename (default: current)
#   --roster PATH      Use this roster instead of building//picking one
#   --org NAME         GitHub org (default: byu-ml-capstone)
#   --coolify-host HOST  ssh target for the Coolify phase when this machine is not
#                      the Coolify host (default: rigel, or $COOLIFY_HOST)
#   --only PHASE       Run a single phase: roster|invite|teams|coolify|verify
#                      Also accepts: gate  (just report who has/hasn't accepted)
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
COOLIFY_HOST="${COOLIFY_HOST:-rigel}"
COOLIFY_DB_CONTAINER="${COOLIFY_DB_CONTAINER:-coolify-db}"
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
        --coolify-host) COOLIFY_HOST="$2"; shift 2 ;;
        --rigel-host)   COOLIFY_HOST="$2"; shift 2 ;;   # legacy alias
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
    # "gate" is checkable on its own but is not a member of PHASES -- putting it
    # there would make "--from teams" skip the gate, which is the documented
    # resume command and must always re-check acceptance.
    [[ "$given" == "gate" && "$label" == "--only" ]] && return 0
    for p in "${PHASES[@]}"; do [[ "$p" == "$given" ]] && return 0; done
    fail "$label: unknown phase '$given'. Valid: ${PHASES[*]}${label:+ (--only also accepts: gate)}"
}
validate_phase_name "$ONLY" "--only"
validate_phase_name "$FROM" "--from"

# Underlying scripts all default to preview and take --apply to execute.
APPLY_FLAG=()
(( APPLY )) && APPLY_FLAG=(--apply)

# ---- "Am I the Coolify host?" --------------------------------------------
# Probe for the capability that actually matters -- a usable local Docker with
# Coolify's Postgres container running -- instead of matching a hostname. The
# Coolify host is rigel today and may not be forever; provision-teams.sh needs
# docker access to coolify-db regardless of what the machine is called.
#
# Echoes: yes | no | denied
coolify_probe() {
    command -v docker >/dev/null 2>&1 || { echo no; return; }
    local out
    if ! out=$(docker ps --format '{{.Names}}' 2>&1); then
        if grep -qi 'permission denied' <<<"$out"; then echo denied; else echo no; fi
        return
    fi
    if grep -qx "$COOLIFY_DB_CONTAINER" <<<"$out"; then echo yes; else echo no; fi
}

# Same probe over ssh, so we never run phase 4 against a host that merely
# answers to the configured name.
coolify_probe_remote() {
    ssh -o BatchMode=yes "$1" \
        "command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx '$COOLIFY_DB_CONTAINER'" \
        >/dev/null 2>&1
}

# Resolve once where Coolify-touching work must happen. Echoes "local" or
# "remote"; fails loudly when neither is possible. Both phase 4 (provisioning)
# and phase 5 (verification) need docker access to coolify-db, so they must
# agree -- running phase 4 over ssh and then phase 5 locally would "verify"
# against a machine that has no Coolify on it.
resolve_coolify_target() {
    case "$(coolify_probe)" in
        yes) echo local; return 0 ;;
        denied)
            fail "Docker is installed here but not usable by $(id -un).
       This looks like the Coolify host, but the probe cannot see its containers.
       Fix with:  sudo usermod -aG docker $(id -un)   then log out and back in." ;;
    esac
    [[ -n "$COOLIFY_HOST" ]] \
        || fail "No --coolify-host given and this machine is not the Coolify host.
       Pass --coolify-host <host>, or run this phase on the machine hosting Coolify."
    ssh -o BatchMode=yes "$COOLIFY_HOST" true 2>/dev/null \
        || fail "cannot ssh to '$COOLIFY_HOST' non-interactively. Fix ssh keys, or run
       this phase directly on the Coolify host."
    coolify_probe_remote "$COOLIFY_HOST" \
        || fail "'$COOLIFY_HOST' is reachable but is NOT running $COOLIFY_DB_CONTAINER.
       Refusing to provision against it. If Coolify has moved, pass the new host
       with --coolify-host (or set COOLIFY_HOST in the environment)."
    echo remote
}

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

    local accepted=$(( total - ${#pending[@]} ))
    if (( ${#pending[@]} == 0 )); then
        good "all $total students have accepted — safe to continue"
        return 0
    fi

    good "$accepted of $total accepted"
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
if [[ "$ONLY" == "gate" ]]; then
    gate_acceptance
    banner "DONE"
    exit 0
fi
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
    # provision-teams.sh writes directly to Coolify's Postgres via docker exec,
    # so this phase MUST execute on the machine running coolify-db.
    COOLIFY_TARGET="$(resolve_coolify_target)"
    if [[ "$COOLIFY_TARGET" == local ]]; then
        good "this machine is running $COOLIFY_DB_CONTAINER — provisioning locally"
        "$SCRIPT_DIR/provision-teams.sh" --check-schema \
            || fail "Coolify schema check failed — do NOT proceed; see onboarding.md step 3a"
        "$SCRIPT_DIR/provision-teams.sh" --roster "$ROSTER" "${APPLY_FLAG[@]}" \
            || fail "provision-teams.sh failed"
    else
        good "$COOLIFY_HOST confirmed running $COOLIFY_DB_CONTAINER"
        # The remote side needs the roster to even build a plan, so it is copied
        # in preview too -- but to a temp path that is removed afterwards, so a
        # preview still leaves nothing behind.
        if (( APPLY )); then
            REMOTE_ROSTER="$(basename "$ROSTER")"
            info "Copying the roster to $COOLIFY_HOST (student PII — gitignored on both ends)."
        else
            REMOTE_ROSTER=".preview-$(basename "$ROSTER")"
            info "Copying the roster to $COOLIFY_HOST as a temp file (removed after the preview)."
        fi
        scp -q "$ROSTER" "$COOLIFY_HOST:~/ml-capstone-platform/$REMOTE_ROSTER" \
            || fail "could not copy the roster to $COOLIFY_HOST"

        # Schema drift after a Coolify auto-upgrade would emit broken INSERTs.
        ssh "$COOLIFY_HOST" "cd ~/ml-capstone-platform && ./scripts/provision-teams.sh --check-schema" \
            || { (( APPLY )) || ssh "$COOLIFY_HOST" "rm -f ~/ml-capstone-platform/$REMOTE_ROSTER"
                 fail "Coolify schema check failed on $COOLIFY_HOST — do NOT proceed; see onboarding.md step 3a"; }

        ssh "$COOLIFY_HOST" "cd ~/ml-capstone-platform && ./scripts/provision-teams.sh --roster '$REMOTE_ROSTER' ${APPLY_FLAG[*]}" \
            || { (( APPLY )) || ssh "$COOLIFY_HOST" "rm -f ~/ml-capstone-platform/$REMOTE_ROSTER"
                 fail "provision-teams.sh failed on $COOLIFY_HOST"; }

        (( APPLY )) || ssh "$COOLIFY_HOST" "rm -f ~/ml-capstone-platform/$REMOTE_ROSTER"
    fi
fi

# ---- Phase 5: verify -----------------------------------------------------
if should_run verify; then
    banner "PHASE 5/5 — verify"
    if (( APPLY )); then
        # verify-provisioning.sh needs BOTH gh AND docker access to coolify-db,
        # so it runs wherever phase 4 ran -- never locally by default.
        if [[ "$(resolve_coolify_target)" == local ]]; then
            "$SCRIPT_DIR/verify-provisioning.sh" --roster "$ROSTER" \
                || fail "verification found problems"
        else
            ssh -o BatchMode=yes "$COOLIFY_HOST" "command -v gh >/dev/null 2>&1 && gh auth status" >/dev/null 2>&1 \
                || fail "verification needs the gh CLI authenticated on $COOLIFY_HOST (it checks
       GitHub membership as well as Coolify's database). Authenticate gh there
       with 'gh auth login', or run verify-provisioning.sh by hand where both
       gh and docker are available."
            # verify-provisioning.sh reads the roster on the remote side, and
            # phase 4 may not have run in this invocation (--only verify), so
            # never assume the file is already there. It is read-only, so the
            # copy is removed afterwards either way.
            VERIFY_ROSTER=".verify-$(basename "$ROSTER")"
            scp -q "$ROSTER" "$COOLIFY_HOST:~/ml-capstone-platform/$VERIFY_ROSTER" \
                || fail "could not copy the roster to $COOLIFY_HOST for verification"
            verify_rc=0
            ssh "$COOLIFY_HOST" "cd ~/ml-capstone-platform && ./scripts/verify-provisioning.sh --roster '$VERIFY_ROSTER'" \
                || verify_rc=$?
            ssh "$COOLIFY_HOST" "rm -f ~/ml-capstone-platform/$VERIFY_ROSTER"
            (( verify_rc == 0 )) || fail "verification found problems on $COOLIFY_HOST"
        fi
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
