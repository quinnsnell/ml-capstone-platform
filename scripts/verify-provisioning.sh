#!/usr/bin/env bash
# =============================================================================
# verify-provisioning.sh — Smoke-test what the three provisioning scripts wrote
#
# After running invite-to-org.sh + provision-gh-teams.sh + provision-teams.sh
# for a roster, this script re-reads the roster and verifies — read-only —
# that every expected artifact actually exists:
#
#   GitHub side (via gh CLI):
#     [GH ] org membership              /orgs/<org>/memberships/<gh_user>
#     [GH ] team exists                 /orgs/<org>/teams/<team-slug>
#     [GH ] team membership             /orgs/<org>/teams/<slug>/memberships/<gh_user>
#
#   Coolify side (via docker exec on rigel):
#     [DB ] users row                   users.email = roster email (lowercased)
#     [DB ] teams row                   teams.name = roster team_name
#     [DB ] team_user pivot             links user↔team with role=admin
#     [DB ] servers row                 name='ml-capstone', team_id set
#     [DB ] server_settings row         has non-null encrypted sentinel_token
#     [DB ] standalone_dockers dest     network='coolify' on that server
#
# It does NOT mutate anything. Safe to re-run.
#
# The UI-side smoke test (impersonate as team, walk Application-create screens
# 1-3 without actually creating) cannot be scripted; it's printed at the end
# as a per-team checklist reminder.
#
# Runs on rigel (needs docker access to coolify-db AND gh CLI authenticated
# as a byu-ml-capstone Owner). All three provisioning scripts already run
# there, so verify runs there too — one host, no split.
#
# Usage:
#   ./verify-provisioning.sh                           # terse table, newest roster-*.csv
#   ./verify-provisioning.sh --roster roster-fall.csv  # explicit roster
#   ./verify-provisioning.sh --verbose                 # per-person grouped block
#   ./verify-provisioning.sh -h                        # this help
#
# Exit codes:
#   0  every check passed for every row
#   2  bad arguments / roster
#   3  preflight failed (gh / docker / db)
#   5  one or more rows had at least one failed check
# =============================================================================

set -u

# ---- Load shared helpers ------------------------------------------------
LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

# ---- Config -------------------------------------------------------------
: "${COOLIFY_DB_CONTAINER:=coolify-db}"
: "${COOLIFY_DB_USER:=coolify}"
: "${COOLIFY_DB_NAME:=coolify}"
: "${ORG:=byu-ml-capstone}"

ROSTER=""
VERBOSE=0
# Observer email (matches provision-teams.sh --observer / OPERATOR_EMAIL).
# If set, we additionally check that this user is admin of every provisioned team.
OBSERVER_EMAIL="${OPERATOR_EMAIL:-}"

# ---- Argument parsing ---------------------------------------------------
usage() { common_usage "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --roster)    ROSTER="$2"; shift 2 ;;
        --observer)  OBSERVER_EMAIL="$2"; shift 2 ;;
        --verbose)   VERBOSE=1; shift ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1" >&2; echo "Run with --help." >&2; exit 2 ;;
    esac
done
[[ -n "$OBSERVER_EMAIL" ]] && OBSERVER_EMAIL="${OBSERVER_EMAIL,,}"

# ---- Slugify — must match provision-gh-teams.sh --------------------------
slugify() {
    local s="$1"
    s=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//')
    printf '%s' "$s"
}

# ---- psql read-only helper ----------------------------------------------
psql_ro() { docker exec -i "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -At -F$'\t' "$@"; }

# ---- Preflight ----------------------------------------------------------
common_banner "PREFLIGHT"
common_gh_org_owner_check "$ORG" || exit $?

if ! command -v docker >/dev/null 2>&1; then
    echo "  docker not found — this script must run on rigel." >&2
    exit 3
fi
if ! docker exec "$COOLIFY_DB_CONTAINER" pg_isready -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" >/dev/null 2>&1; then
    echo "  Cannot reach Postgres in container '$COOLIFY_DB_CONTAINER'." >&2
    echo "  Is Coolify running? Try: docker ps | grep coolify-db" >&2
    exit 3
fi
printf '  Coolify DB:       reachable (%s)\n' "$COOLIFY_DB_CONTAINER"
common_banner_end

# ---- Pick roster --------------------------------------------------------
ROSTER=$(common_pick_roster "$ROSTER") || exit $?
[[ -r "$ROSTER" ]] || { echo "Cannot read $ROSTER" >&2; exit 2; }

# ---- Parse header -------------------------------------------------------
declare -A COL_IDX=()
common_csv_parse_header COL_IDX "$ROSTER"
for required in team_name email name; do
    common_csv_require_column COL_IDX "$required" || exit 2
done

# ---- Snapshot DB state once (avoid per-row queries for a 30-student roster) ----
DB_EMAILS=$(psql_ro -c "SELECT email FROM users;")
DB_TEAMS=$(psql_ro -c "SELECT name FROM teams;")
DB_PIVOTS=$(psql_ro -c "SELECT t.name || E'\t' || u.email FROM team_user tu JOIN teams t ON t.id = tu.team_id JOIN users u ON u.id = tu.user_id;")
DB_SERVERS=$(psql_ro -c "SELECT t.name FROM servers s JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")
DB_SETTINGS_OK=$(psql_ro -c "SELECT t.name FROM server_settings ss JOIN servers s ON s.id = ss.server_id JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL AND ss.sentinel_token IS NOT NULL AND length(ss.sentinel_token) >= 100;")
DB_DESTINATIONS=$(psql_ro -c "SELECT t.name FROM standalone_dockers sd JOIN servers s ON s.id = sd.server_id JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL AND sd.network = 'coolify';")

# Observer team memberships (empty set if OBSERVER_EMAIL unset).
DB_OBSERVER_TEAMS=""
if [[ -n "$OBSERVER_EMAIL" ]]; then
    esc_obs=${OBSERVER_EMAIL//\'/\'\'}
    DB_OBSERVER_TEAMS=$(psql_ro -c "SELECT t.name FROM team_user tu JOIN teams t ON t.id = tu.team_id JOIN users u ON u.id = tu.user_id WHERE u.email = '$esc_obs';")
fi

# Fixed-string exact-line grep against a $'\n'-separated list
has_line() { grep -qxF -- "$2" <<<"$1"; }

# ---- Verify each row ----------------------------------------------------
common_banner "VERIFY"
echo "  Roster:  $ROSTER"
echo "  Org:     $ORG"
echo

# Column headers for terse mode
if (( ! VERBOSE )); then
    printf '  %-24s %-24s %-32s  %s\n' "team" "github" "email" "GH:org|team|memb  DB:user|team|piv|srv|set|dest"
    printf '  %s\n' "----------------------------------------------------------------------------------------------------------------------"
fi

total_rows=0
failed_rows=0
declare -a UNIQUE_TEAMS_FOR_CHECKLIST=()

row_num=1
while IFS= read -r line || [[ -n "$line" ]]; do
    row_num=$((row_num + 1))
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    line=${line%$'\r'}
    IFS=',' read -r -a F <<<"$line"

    team_name=$(common_trim "${F[${COL_IDX[team_name]}]}")
    email=$(common_trim "${F[${COL_IDX[email]}]}")
    email=${email,,}
    name=$(common_trim "${F[${COL_IDX[name]}]}")
    gh_user=""
    [[ -n "${COL_IDX[github_username]+set}" ]] && gh_user=$(common_trim "${F[${COL_IDX[github_username]}]:-}")

    [[ -z "$team_name" || -z "$email" ]] && continue

    total_rows=$((total_rows + 1))
    slug=$(slugify "$team_name")

    # Track unique teams for the closing checklist
    already_have=0
    for t in "${UNIQUE_TEAMS_FOR_CHECKLIST[@]:-}"; do
        [[ "$t" == "$team_name" ]] && already_have=1 && break
    done
    (( already_have )) || UNIQUE_TEAMS_FOR_CHECKLIST+=("$team_name")

    # ---- GitHub checks ----
    gh_org="?"; gh_team="?"; gh_memb="?"
    if [[ -n "$gh_user" ]]; then
        state=$(gh api "/orgs/$ORG/memberships/$gh_user" --jq .state 2>/dev/null || echo "")
        [[ "$state" == "active" ]] && gh_org="OK" || gh_org="MISS"

        if gh api "/orgs/$ORG/teams/$slug" >/dev/null 2>&1; then
            gh_team="OK"
            m_state=$(gh api "/orgs/$ORG/teams/$slug/memberships/$gh_user" --jq .state 2>/dev/null || echo "")
            [[ "$m_state" == "active" ]] && gh_memb="OK" || gh_memb="MISS"
        else
            gh_team="MISS"
            gh_memb="MISS"
        fi
    else
        # No github_username in this row — skip GH checks (not a failure).
        gh_org="n/a"; gh_team="n/a"; gh_memb="n/a"
    fi

    # ---- DB checks ----
    db_user="MISS";  has_line "$DB_EMAILS"          "$email"                       && db_user="OK"
    db_team="MISS";  has_line "$DB_TEAMS"           "$team_name"                   && db_team="OK"
    db_piv="MISS";   has_line "$DB_PIVOTS"          "${team_name}"$'\t'"${email}"  && db_piv="OK"
    db_srv="MISS";   has_line "$DB_SERVERS"         "$team_name"                   && db_srv="OK"
    db_set="MISS";   has_line "$DB_SETTINGS_OK"     "$team_name"                   && db_set="OK"
    db_dest="MISS";  has_line "$DB_DESTINATIONS"    "$team_name"                   && db_dest="OK"
    if [[ -n "$OBSERVER_EMAIL" ]]; then
        db_obs="MISS"; has_line "$DB_OBSERVER_TEAMS" "$team_name" && db_obs="OK"
    else
        db_obs="n/a"
    fi

    # Compute per-row pass/fail. n/a doesn't count against.
    row_failed=0
    for v in "$gh_org" "$gh_team" "$gh_memb" "$db_user" "$db_team" "$db_piv" "$db_srv" "$db_set" "$db_dest" "$db_obs"; do
        [[ "$v" == "MISS" ]] && row_failed=1
    done
    (( row_failed )) && failed_rows=$((failed_rows + 1))

    marker=$([[ $row_failed -eq 0 ]] && echo "✓" || echo "✗")

    if (( VERBOSE )); then
        printf '\n  === Row %d: %s (%s, %s, team="%s") ===\n' \
            "$row_num" "${name:-?}" "${gh_user:-<no github>}" "$email" "$team_name"
        printf '    [GH ] org member                     %s\n' "$gh_org"
        printf '    [GH ] team %-30s %s\n' "$slug" "$gh_team"
        printf '    [GH ] team membership                %s\n' "$gh_memb"
        printf '    [DB ] users row                      %s\n' "$db_user"
        printf '    [DB ] teams row                      %s\n' "$db_team"
        printf '    [DB ] team_user pivot                %s\n' "$db_piv"
        printf '    [DB ] servers row (ml-capstone)      %s\n' "$db_srv"
        printf '    [DB ] server_settings (has token)    %s\n' "$db_set"
        printf '    [DB ] standalone_dockers destination %s\n' "$db_dest"
        printf '    [DB ] observer (%s) is team admin  %s\n' "${OBSERVER_EMAIL:-<unset>}" "$db_obs"
        printf '    RESULT: %s\n' "$marker"
    else
        # Terse: one line per row, ✓/✗ per check
        gh_col=$(printf '%s|%s|%s' "$gh_org" "$gh_team" "$gh_memb")
        db_col=$(printf '%s|%s|%s|%s|%s|%s|obs:%s' "$db_user" "$db_team" "$db_piv" "$db_srv" "$db_set" "$db_dest" "$db_obs")
        printf '  %s %-22s %-24s %-32s  %-19s  %s\n' \
            "$marker" "$team_name" "${gh_user:-<no github>}" "$email" "$gh_col" "$db_col"
    fi
done < <(tail -n +2 "$ROSTER")

echo
printf '  Rollup: %d row(s) checked, %d passed, %d failed\n' \
    "$total_rows" "$((total_rows - failed_rows))" "$failed_rows"
common_banner_end

# ---- Layer 3 checklist reminder -----------------------------------------
common_banner "MANUAL UI SMOKE TEST (cannot script — do once per team)"
if [[ -n "$OBSERVER_EMAIL" ]]; then
    printf '  Since you were added as admin of every team via --observer, they all\n'
    printf '  appear in Coolify'"'"'s team switcher under your own login (%s).\n' "$OBSERVER_EMAIL"
    printf '  No DB-dance needed. Sign in and walk each team:\n\n'
else
    cat <<'EOF'
  You didn't pass --observer, so provisioned teams don't appear in your
  team switcher. Either re-run provision-teams.sh --observer <you>@..., or
  do the manual DB-dance the old-fashioned way (add self as team_user row,
  walk, delete the row) — see onboarding.md §4.

EOF
fi
cat <<'EOF'
  For each provisioned team, switch to it in the team switcher and verify:

    [ ]  Servers → 'ml-capstone' shows green "reachable"
    [ ]  Click into ml-capstone → server-show page loads (no 500)
         (this is where the encrypted sentinel_token bug bites)
    [ ]  Projects → + New Project (throwaway name) → into production env
         → + Add Resource → Private Repository (with GitHub App)
    [ ]  Screen 1: destination 'coolify' is pickable
    [ ]  Screen 2: source 'byu-ml-capstone-coolify' is pickable
    [ ]  Screen 3: Load Repository → org repos listed (incl. hello-world-app)
    [ ]  Bail on Screen 4; delete the throwaway Project (Danger Zone)

  Teams to walk through:
EOF
for t in "${UNIQUE_TEAMS_FOR_CHECKLIST[@]:-}"; do
    printf '    - %s\n' "$t"
done
common_banner_end
echo

if (( failed_rows > 0 )); then
    echo "VERIFY FAILED — $failed_rows row(s) had at least one missing check." >&2
    echo "Re-run with --verbose to see per-check detail per row." >&2
    exit 5
fi

echo "SUCCESS: all $total_rows roster row(s) passed every scripted check."
echo "Complete the manual UI walkthrough above before handing off to students."
