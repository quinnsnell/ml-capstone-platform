#!/usr/bin/env bash
# =============================================================================
# provision-teams.sh — Idempotent team + user provisioning for Coolify (v4.2+)
#
# Reads a roster CSV and creates Coolify Teams + user rows so students can sign
# in via GitHub OAuth (which is invite-only — "Registration Allowed" is off).
#
# Coolify's REST API does NOT cover team creation or user invitation as of 4.2,
# so this script writes directly to Coolify's Postgres. See
# `memory/coolify_oauth_setup.md` for the rationale.
#
# Design:
#   - Fully idempotent (safe to re-run mid-term as CSV grows)
#   - Dry-run by default; --apply to execute
#   - Emails lowercased before insert (Coolify issue #6291)
#   - Pivot role is 'admin' (v4.2 broke the 'member' role)
#
# CSV shape — one row per (team, user) pair:
#   team_name,email,name,github_username
#   Alice's Sandbox,alice@byu.edu,Alice Smith,alice-s
#   Group 1,alice@byu.edu,Alice Smith,alice-s
#   Group 1,bob@byu.edu,Bob Jones,bjones
#
# Multiple rows per user = user belongs to multiple teams. That's how the
# "individual phase → group phase" arc works: Phase-1 rows stay, Phase-2 rows
# get appended. Individual sandboxes live alongside group teams.
#
# Requires: bash, docker (with access to coolify-db), no other deps.
# Run this ON RIGEL as a user in the docker group (or with sudo).
#
# Usage:
#   ./provision-teams.sh                        # dry-run, newest roster-*.csv
#   ./provision-teams.sh --apply                # execute for real
#   ./provision-teams.sh --roster path.csv      # explicit roster file
#   ./provision-teams.sh --check-schema         # dump users/teams/team_user schema, exit
#   ./provision-teams.sh -h                     # this help
# =============================================================================

set -u

# ---- Config -------------------------------------------------------------
: "${COOLIFY_DB_CONTAINER:=coolify-db}"
: "${COOLIFY_DB_USER:=coolify}"
: "${COOLIFY_DB_NAME:=coolify}"

APPLY=0
CHECK_SCHEMA=0
ROSTER=""

# ---- Argument parsing ---------------------------------------------------
usage() {
    sed -n '2,/^# ===*$/{ /^# ===*$/d; s/^# \{0,1\}//p; }' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)         APPLY=1; shift ;;
        --roster)        ROSTER="$2"; shift 2 ;;
        --check-schema)  CHECK_SCHEMA=1; shift ;;
        -h|--help)       usage ;;
        *) echo "Unknown option: $1" >&2; echo "Run with --help." >&2; exit 2 ;;
    esac
done

# ---- Postgres helper ----------------------------------------------------
# psql invocations run inside the coolify-db container. -A: unaligned output,
# -t: tuples only, -F: field separator (for parsing).
psql_ro()  { docker exec -i "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -At -F$'\t' "$@"; }
psql_exec() { docker exec -i "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -v ON_ERROR_STOP=1 "$@"; }

# ---- --check-schema ----------------------------------------------------
if (( CHECK_SCHEMA )); then
    echo "=== users ===";      docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -c '\d users'
    echo "=== teams ===";      docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -c '\d teams'
    echo "=== team_user ==="; docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -c '\d team_user'
    exit 0
fi

# ---- Pick roster --------------------------------------------------------
if [[ -z "$ROSTER" ]]; then
    ROSTER=$(ls -1t roster-*.csv 2>/dev/null | head -n1 || true)
    if [[ -z "$ROSTER" ]]; then
        echo "No --roster given and no roster-*.csv in $(pwd)." >&2
        echo "Create one — see example at roster-example.csv." >&2
        exit 2
    fi
    echo "Auto-picked roster: $ROSTER"
fi
[[ -r "$ROSTER" ]] || { echo "Cannot read $ROSTER" >&2; exit 2; }

# ---- Sanity: DB reachable + expected tables exist ----------------------
if ! docker exec "$COOLIFY_DB_CONTAINER" pg_isready -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" >/dev/null 2>&1; then
    echo "Cannot reach Postgres in container '$COOLIFY_DB_CONTAINER'." >&2
    echo "Is Coolify running? Try: docker ps | grep coolify-db" >&2
    exit 3
fi

for tbl in users teams team_user; do
    if ! psql_ro -c "SELECT 1 FROM $tbl LIMIT 1" >/dev/null 2>&1; then
        echo "Table '$tbl' not found or unreadable — Coolify schema mismatch?" >&2
        echo "Run with --check-schema to inspect." >&2
        exit 3
    fi
done

# ---- Generate a placeholder bcrypt hash (via PHP in the coolify container)
# Users we create authenticate via OAuth; the password column exists in Laravel's
# users table and is often NOT NULL. We seed a random un-guessable hash so the
# row is valid and the email/password login form cannot succeed for these rows.
PLACEHOLDER_HASH=$(docker exec coolify php -r 'echo password_hash(bin2hex(random_bytes(32)), PASSWORD_BCRYPT);' 2>/dev/null || true)
if [[ -z "$PLACEHOLDER_HASH" ]]; then
    echo "Warning: could not generate bcrypt hash via 'coolify' container; falling back to empty string." >&2
    echo "If the users.password column is NOT NULL, inserts will fail — investigate." >&2
    PLACEHOLDER_HASH=''
fi

# ---- Read + validate CSV ------------------------------------------------
# Parse header, verify required columns present.
HEADER=$(head -n1 "$ROSTER" | tr -d '\r')
IFS=',' read -r -a COLS <<<"$HEADER"
declare -A COL_IDX=()
for i in "${!COLS[@]}"; do COL_IDX["${COLS[$i]}"]=$i; done
for required in team_name email name; do
    if [[ -z "${COL_IDX[$required]+set}" ]]; then
        echo "Roster missing required column '$required'. Got: $HEADER" >&2
        exit 2
    fi
done

# ---- Build SQL ----------------------------------------------------------
# One transactional batch. Emits three sections per row:
#   (a) upsert user by lowercased email
#   (b) upsert team by name
#   (c) upsert team_user pivot (team_id, user_id, role='admin')
SQL_FILE=$(mktemp -t provision-teams.XXXXXX.sql)
trap 'rm -f "$SQL_FILE"' EXIT

{
    echo "BEGIN;"
    echo "-- Generated by provision-teams.sh from $ROSTER on $(date -u +%FT%TZ)"
    echo

    tail -n +2 "$ROSTER" | while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        line=${line%$'\r'}
        IFS=',' read -r -a F <<<"$line"

        team_name=${F[${COL_IDX[team_name]}]}
        email_raw=${F[${COL_IDX[email]}]}
        name=${F[${COL_IDX[name]}]}
        # tolerate missing github_username column
        gh=""
        [[ -n "${COL_IDX[github_username]+set}" ]] && gh=${F[${COL_IDX[github_username]}]:-}

        # lowercase email
        email=$(echo "$email_raw" | tr '[:upper:]' '[:lower:]' | xargs)
        team_name=$(echo "$team_name" | xargs)
        name=$(echo "$name" | xargs)

        # SQL escape — double single quotes
        e_email=${email//\'/\'\'}
        e_team_name=${team_name//\'/\'\'}
        e_name=${name//\'/\'\'}
        e_gh=${gh//\'/\'\'}

        cat <<SQL
-- Row: team=$team_name, user=$email
INSERT INTO users (name, email, email_verified_at, password, created_at, updated_at)
VALUES ('$e_name', '$e_email', NOW(), '$PLACEHOLDER_HASH', NOW(), NOW())
ON CONFLICT (email) DO NOTHING;

INSERT INTO teams (name, description, personal_team, created_at, updated_at)
SELECT '$e_team_name', 'Provisioned by provision-teams.sh${e_gh:+ (github=$e_gh)}', false, NOW(), NOW()
WHERE NOT EXISTS (SELECT 1 FROM teams WHERE name = '$e_team_name');

INSERT INTO team_user (team_id, user_id, role, created_at, updated_at)
SELECT t.id, u.id, 'admin', NOW(), NOW()
FROM teams t, users u
WHERE t.name = '$e_team_name' AND u.email = '$e_email'
ON CONFLICT (team_id, user_id) DO NOTHING;

SQL
    done

    echo "COMMIT;"
} >"$SQL_FILE"

echo
echo "===================================================================="
echo "Roster:    $ROSTER"
echo "Rows:      $(( $(wc -l <"$ROSTER") - 1 ))"
echo "Target:    docker exec $COOLIFY_DB_CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME"
echo "Mode:      $([[ $APPLY == 1 ]] && echo "APPLY" || echo "dry-run (use --apply to execute)")"
echo "SQL file:  $SQL_FILE"
echo "===================================================================="
echo

if (( ! APPLY )); then
    echo "--- SQL preview (dry-run) ---"
    cat "$SQL_FILE"
    echo "--- end preview ---"
    echo
    echo "Re-run with --apply to execute."
    exit 0
fi

# ---- Apply --------------------------------------------------------------
echo "Executing…"
if ! psql_exec <"$SQL_FILE"; then
    echo "SQL execution failed — transaction rolled back. Inspect $SQL_FILE above." >&2
    exit 4
fi

echo
echo "--- Post-apply summary ---"
psql_ro -c "SELECT id, LEFT(name, 40) AS name FROM teams ORDER BY id;"
echo
psql_ro -c "SELECT COUNT(*) AS user_rows FROM users;"
psql_ro -c "SELECT COUNT(*) AS team_user_links FROM team_user;"
echo
echo "Done. Students with rows in 'users' can now sign in via GitHub OAuth"
echo "using the email in their row. Coolify will link the account on first login."
