#!/usr/bin/env bash
# =============================================================================
# invite-to-org.sh — Invite roster users to the class GitHub org
#
# Runs from your laptop (or anywhere with `gh` CLI authenticated). Reads the
# same roster CSV as provision-teams.sh and sends a GitHub org invitation to
# each row's `github_username`. Idempotent: users who are already members or
# have a pending invite are skipped.
#
# Runs BEFORE (or alongside) provision-teams.sh. Students should accept the
# org invitation before they use the "Use this template" flow on hello-world-app
# — otherwise they can't create their repo inside the org.
#
# Required: gh CLI, authenticated as an Owner of the target org (org-invite
# permission requires the `admin:org` scope on classic tokens, or
# "Organization administration" write access on fine-grained tokens).
#
# CSV columns used:
#   - github_username  (required — row is skipped with a warning if empty)
#
# Usage:
#   ./invite-to-org.sh                             # dry-run, newest roster-*.csv, org=byu-ml-capstone
#   ./invite-to-org.sh --apply                     # send invitations
#   ./invite-to-org.sh --roster path.csv --apply
#   ./invite-to-org.sh --org other-org --apply
#   ./invite-to-org.sh -h                          # help
# =============================================================================

set -u

# ---- Config -------------------------------------------------------------
: "${ORG:=byu-ml-capstone}"
APPLY=0
ROSTER=""

usage() {
    sed -n '2,/^# ===*$/{ /^# ===*$/d; s/^# \{0,1\}//p; }' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)  APPLY=1; shift ;;
        --roster) ROSTER="$2"; shift 2 ;;
        --org)    ORG="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; echo "Run with --help." >&2; exit 2 ;;
    esac
done

# ---- Preflight: gh auth + org owner check -------------------------------
echo
echo "============================ PREFLIGHT ============================"

if ! command -v gh >/dev/null 2>&1; then
    echo "  gh CLI not found. Install: https://cli.github.com/" >&2
    exit 3
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "  gh not authenticated. Run: gh auth login" >&2
    exit 3
fi

caller=$(gh api /user --jq .login 2>/dev/null || echo "")
[[ -z "$caller" ]] && { echo "  Could not resolve authenticated user via gh api /user" >&2; exit 3; }
printf '  gh authenticated as: %s\n' "$caller"

role=$(gh api "/orgs/$ORG/memberships/$caller" --jq .role 2>/dev/null || echo "none")
if [[ "$role" != "admin" ]]; then
    echo "  ERROR: caller '$caller' is not an Owner of '$ORG' (role=$role)." >&2
    echo "  Ownership required to send org invitations." >&2
    exit 3
fi
printf '  Owner role on %s: verified\n' "$ORG"

echo "==================================================================="

# ---- Pick roster --------------------------------------------------------
if [[ -z "$ROSTER" ]]; then
    ROSTER=$(ls -1t roster-*.csv 2>/dev/null | head -n1 || true)
    if [[ -z "$ROSTER" ]]; then
        echo "No --roster given and no roster-*.csv in $(pwd)." >&2
        exit 2
    fi
    echo "Auto-picked roster: $ROSTER"
fi
[[ -r "$ROSTER" ]] || { echo "Cannot read $ROSTER" >&2; exit 2; }

# ---- Parse header + validate columns ------------------------------------
HEADER=$(head -n1 "$ROSTER" | tr -d '\r')
IFS=',' read -r -a COLS <<<"$HEADER"
declare -A COL_IDX=()
for i in "${!COLS[@]}"; do COL_IDX["${COLS[$i]}"]=$i; done
if [[ -z "${COL_IDX[github_username]+set}" ]]; then
    echo "Roster missing required column 'github_username'. Got: $HEADER" >&2
    exit 2
fi
# email column is optional, used only for display
email_idx="${COL_IDX[email]:--1}"

# ---- Compute plan -------------------------------------------------------
# For each row: query GitHub for the user's membership state in the org.
# Emit per-row status: EXISTS-active, EXISTS-pending, INVITE (new), or SKIP.

echo
echo "============================== PLAN ==============================="
echo "  Roster:  $ROSTER"
echo "  Org:     $ORG"
echo "  Mode:    $([[ $APPLY == 1 ]] && echo "APPLY" || echo "dry-run (use --apply to send)")"
echo

new_invites=0
active_members=0
pending_members=0
skipped_rows=0

# Process substitution so `exit` inside the loop actually aborts.
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    line=${line%$'\r'}
    IFS=',' read -r -a F <<<"$line"

    gh_user=$(echo "${F[${COL_IDX[github_username]}]:-}" | tr -d ' \r\n')
    email=""
    (( email_idx >= 0 )) && email=$(echo "${F[$email_idx]:-}" | tr -d ' \r\n')

    if [[ -z "$gh_user" ]]; then
        printf '  SKIP     (no github_username in row; email=%s)\n' "${email:-?}"
        skipped_rows=$((skipped_rows + 1))
        continue
    fi

    # Query membership state
    state=$(gh api "/orgs/$ORG/memberships/$gh_user" --jq .state 2>/dev/null || echo "none")

    case "$state" in
        active)
            printf '  EXISTS   %-25s active member\n' "$gh_user"
            active_members=$((active_members + 1))
            ;;
        pending)
            printf '  PENDING  %-25s invitation already sent, not accepted yet\n' "$gh_user"
            pending_members=$((pending_members + 1))
            ;;
        *)
            if (( APPLY )); then
                if gh api -X PUT "/orgs/$ORG/memberships/$gh_user" -f role=member >/dev/null 2>&1; then
                    printf '  INVITE   %-25s sent\n' "$gh_user"
                else
                    printf '  FAIL     %-25s API call failed (does the account exist?)\n' "$gh_user"
                    skipped_rows=$((skipped_rows + 1))
                    continue
                fi
            else
                printf '  INVITE   %-25s would send\n' "$gh_user"
            fi
            new_invites=$((new_invites + 1))
            ;;
    esac
done < <(tail -n +2 "$ROSTER")

echo
echo "  Rollup:                     COUNT"
printf '    new invitations           %5d\n' "$new_invites"
printf '    existing active members   %5d\n' "$active_members"
printf '    pending (not accepted)    %5d\n' "$pending_members"
printf '    skipped (no username/fail) %4d\n' "$skipped_rows"
echo "==================================================================="

if (( ! APPLY )); then
    echo
    if (( new_invites > 0 )); then
        echo "READY: $new_invites invitation(s) will be sent on --apply."
    else
        echo "NO-OP: every roster user is already a member or has a pending invite."
    fi
    echo "Re-run with --apply to execute."
    exit 0
fi

echo
echo "SUCCESS: $new_invites invitation(s) sent."
echo "Students will receive an email + GitHub notification. They must accept before"
echo "they can create repos inside $ORG (student-guide.md Step 4)."
