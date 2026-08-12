#!/usr/bin/env bash
# =============================================================================
# provision-gh-teams.sh — Create GitHub Teams in the class org + add members
#
# Mirrors the Coolify team structure into GitHub Teams so groups can be granted
# repo access as a unit instead of one-by-one collaborator adds. GitHub Teams
# are separate from Coolify Teams but line up naturally — both slice the roster
# the same way.
#
# For each unique `team_name` in the roster:
#   1. Ensure a GitHub Team exists with slug = lowercase-dashed(team_name)
#      (e.g., "Alice's Sandbox" -> alice-s-sandbox; "Group 1" -> group-1)
#   2. Add every roster row's `github_username` to that Team as a member
#
# Runs from your laptop (needs `gh` CLI authenticated as an Owner of the target
# org). Idempotent — teams that already exist are reused, members already in a
# team are skipped.
#
# WHAT THIS DOES NOT DO (out of scope by design):
#   - Does NOT grant Teams access to specific repos. That happens per-repo,
#     typically when a group creates their repo from the template. Grant via:
#       gh api -X PUT /orgs/<org>/teams/<team-slug>/repos/<org>/<repo> -f permission=push
#   - Does NOT invite users to the org — run scripts/invite-to-org.sh first.
#     Users must already be org members before they can join a Team.
#
# CSV columns used:
#   - team_name        (required — used to derive the GitHub Team slug)
#   - github_username  (required — row is skipped with a warning if empty)
#
# Usage:
#   ./provision-gh-teams.sh                              # dry-run, newest roster-*.csv, org=byu-ml-capstone
#   ./provision-gh-teams.sh --apply                      # execute
#   ./provision-gh-teams.sh --roster path.csv --apply
#   ./provision-gh-teams.sh --org other-org --apply
#   ./provision-gh-teams.sh -h                           # help
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

# ---- Small helpers ------------------------------------------------------
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Deterministic team name -> team slug: lowercase, replace non-alnum runs with '-',
# collapse repeats, trim leading/trailing dashes.
# Examples:
#   "Alice's Sandbox" -> "alice-s-sandbox"
#   "Group 1"         -> "group-1"
slugify() {
    local s="$1"
    s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//')
    printf '%s' "$s"
}

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
    echo "  Owner role required to create/manage GitHub Teams." >&2
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
for req in team_name github_username; do
    if [[ -z "${COL_IDX[$req]+set}" ]]; then
        echo "Roster missing required column '$req'. Got: $HEADER" >&2
        exit 2
    fi
done

# ---- Build in-memory plan -----------------------------------------------
# Two passes over the CSV:
#   Pass 1 — collect unique team_names + their slugs, and per-team member lists.
#   Pass 2 — for each team, ensure it exists and each member is added.

declare -A TEAM_SLUG=()   # team_name -> slug
declare -A TEAM_MEMBERS=() # slug -> space-separated github usernames

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    line=${line%$'\r'}
    IFS=',' read -r -a F <<<"$line"

    team_name=$(trim "${F[${COL_IDX[team_name]}]:-}")
    gh_user=$(echo "${F[${COL_IDX[github_username]}]:-}" | tr -d ' \r\n')

    [[ -z "$team_name" ]] && continue
    if [[ -z "$gh_user" ]]; then
        printf '  WARN     no github_username for team=%s (row will be skipped)\n' "$team_name" >&2
        continue
    fi

    slug=$(slugify "$team_name")
    TEAM_SLUG[$team_name]="$slug"
    TEAM_MEMBERS[$slug]="${TEAM_MEMBERS[$slug]:-} $gh_user"
done < <(tail -n +2 "$ROSTER")

if (( ${#TEAM_SLUG[@]} == 0 )); then
    echo "No valid team_name+github_username rows in roster. Nothing to do." >&2
    exit 0
fi

# ---- Plan ---------------------------------------------------------------
echo
echo "============================== PLAN ==============================="
echo "  Roster:  $ROSTER"
echo "  Org:     $ORG"
echo "  Mode:    $([[ $APPLY == 1 ]] && echo "APPLY" || echo "dry-run (use --apply to execute)")"
echo
echo "  Teams to ensure exist + their members:"
teams_to_create=0
teams_existing=0
members_to_add=0
members_existing=0

for team_name in "${!TEAM_SLUG[@]}"; do
    slug="${TEAM_SLUG[$team_name]}"
    # Trim + de-duplicate members
    members=$(echo "${TEAM_MEMBERS[$slug]}" | tr ' ' '\n' | sort -u | grep -v '^$')

    # Does the team already exist?
    team_state=$(gh api "/orgs/$ORG/teams/$slug" --jq .slug 2>/dev/null || echo "")
    if [[ -n "$team_state" ]]; then
        team_marker="EXISTS "
        teams_existing=$((teams_existing + 1))
    else
        team_marker="CREATE "
        teams_to_create=$((teams_to_create + 1))
    fi
    printf '\n  %s Team "%s"  (slug: %s)\n' "$team_marker" "$team_name" "$slug"

    while read -r member; do
        [[ -z "$member" ]] && continue
        # Check membership
        m_state=""
        if [[ -n "$team_state" ]]; then
            m_state=$(gh api "/orgs/$ORG/teams/$slug/memberships/$member" --jq .state 2>/dev/null || echo "")
        fi
        case "$m_state" in
            active)
                printf '      EXISTS   %s (already in team)\n' "$member"
                members_existing=$((members_existing + 1))
                ;;
            pending)
                printf '      PENDING  %s (invite sent, not accepted)\n' "$member"
                members_existing=$((members_existing + 1))
                ;;
            *)
                printf '      ADD      %s\n' "$member"
                members_to_add=$((members_to_add + 1))
                ;;
        esac
    done <<< "$members"
done

echo
echo "  Rollup:                     COUNT"
printf '    teams to create           %5d\n' "$teams_to_create"
printf '    teams already existing    %5d\n' "$teams_existing"
printf '    members to add            %5d\n' "$members_to_add"
printf '    members already in team   %5d\n' "$members_existing"
echo "==================================================================="

if (( ! APPLY )); then
    echo
    if (( teams_to_create == 0 && members_to_add == 0 )); then
        echo "NO-OP: every team + member already provisioned."
    else
        echo "READY: --apply will create $teams_to_create team(s) and add $members_to_add member(s)."
    fi
    echo "Re-run with --apply to execute."
    exit 0
fi

# ---- Apply --------------------------------------------------------------
echo
echo "Executing…"

for team_name in "${!TEAM_SLUG[@]}"; do
    slug="${TEAM_SLUG[$team_name]}"

    # Ensure team exists
    team_state=$(gh api "/orgs/$ORG/teams/$slug" --jq .slug 2>/dev/null || echo "")
    if [[ -z "$team_state" ]]; then
        gh api -X POST "/orgs/$ORG/teams" \
            -f name="$team_name" \
            -f description="Provisioned by provision-gh-teams.sh from roster" \
            -f privacy="closed" >/dev/null
        printf '  CREATED  team "%s" (slug=%s)\n' "$team_name" "$slug"
    fi

    # Add members
    members=$(echo "${TEAM_MEMBERS[$slug]}" | tr ' ' '\n' | sort -u | grep -v '^$')
    while read -r member; do
        [[ -z "$member" ]] && continue
        m_state=$(gh api "/orgs/$ORG/teams/$slug/memberships/$member" --jq .state 2>/dev/null || echo "")
        if [[ "$m_state" == "active" || "$m_state" == "pending" ]]; then
            continue
        fi
        if gh api -X PUT "/orgs/$ORG/teams/$slug/memberships/$member" -f role=member >/dev/null 2>&1; then
            printf '  ADDED    %s -> %s\n' "$member" "$slug"
        else
            printf '  FAIL     could not add %s to %s (does the account exist?)\n' "$member" "$slug"
        fi
    done <<< "$members"
done

echo
echo "SUCCESS: teams provisioned."
echo
echo "Next step (per-repo, when a group creates their repo from the template):"
echo "  gh api -X PUT /orgs/$ORG/teams/<team-slug>/repos/$ORG/<repo-name> -f permission=push"
echo "This grants the GitHub Team Write access to that repo. Everyone in the team can push."
