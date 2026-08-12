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
# Because direct DB writes are brittle across Coolify versions, every invocation
# runs three phases:
#   1. PREFLIGHT — verify Coolify version + every column we INSERT into exists
#      with the expected name. If Coolify has renamed/removed a column in an
#      upgrade, we abort loudly rather than emitting a broken INSERT.
#   2. PLAN — per-row and rollup summary showing what will happen for each of
#      the 5 tables (users / teams / team_user / servers / server_settings):
#      CREATE (row is new) or EXISTS (idempotent no-op). Shown in dry-run and
#      before --apply so you can sanity-check.
#   3. APPLY (only with --apply) — execute the SQL, then VERIFY by re-querying
#      to confirm every row's expected end state is present.
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
# For each unique team, also provisions a Server row named 'ml-capstone' pointing
# at host.docker.internal so team members can create Applications. Idempotent
# on (team_id, name='ml-capstone') — safe to re-run.
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
#   ./provision-teams.sh --show-sql             # also print the raw SQL (default: plan only)
#   ./provision-teams.sh -h                     # this help
# =============================================================================

set -u

# ---- Config -------------------------------------------------------------
: "${COOLIFY_DB_CONTAINER:=coolify-db}"
: "${COOLIFY_DB_USER:=coolify}"
: "${COOLIFY_DB_NAME:=coolify}"

APPLY=0
CHECK_SCHEMA=0
SHOW_SQL=0
ROSTER=""

# Coolify versions this script has been proven against. New minors are likely
# fine but flag them so the operator can decide.
KNOWN_GOOD_MAJOR_MINOR="4.2"

# ---- Small helpers ------------------------------------------------------
# Pure-bash whitespace trim. Handles apostrophes/quotes/anything else literally —
# DO NOT use xargs for this (it parses shell quoting and blows up on unmatched
# single quotes like "Quinn's Sandbox").
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

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
        --show-sql)      SHOW_SQL=1; shift ;;
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

# ---- Preflight: Coolify version + schema fingerprint --------------------
echo
echo "============================ PREFLIGHT ============================"

# Detect Coolify version from the image tag on the running container.
COOLIFY_IMAGE=$(docker inspect coolify --format '{{.Config.Image}}' 2>/dev/null || echo "")
COOLIFY_VERSION="${COOLIFY_IMAGE##*:}"
if [[ -z "$COOLIFY_VERSION" ]]; then
    COOLIFY_VERSION="unknown"
fi

version_status="untested"
case "$COOLIFY_VERSION" in
    ${KNOWN_GOOD_MAJOR_MINOR}.*) version_status="known-good" ;;
    latest)                       version_status="floating tag — verify the running version elsewhere" ;;
esac
printf '  Coolify version:  %s (%s; script proven against %s.x)\n' \
    "$COOLIFY_VERSION" "$version_status" "$KNOWN_GOOD_MAJOR_MINOR"

# Check every table + every column we're about to INSERT into. If Coolify
# renames or removes any of these on upgrade, abort loudly here rather than
# emitting a broken SQL batch that partially applies.
declare -A REQUIRED_COLS=(
  [users]="email name password email_verified_at created_at updated_at"
  [teams]="name description personal_team created_at updated_at"
  [team_user]="team_id user_id role created_at updated_at"
  [servers]="uuid name description ip port user team_id private_key_id proxy sentinel_updated_at deleted_at created_at updated_at"
  [server_settings]="server_id is_reachable is_usable is_sentinel_enabled sentinel_token created_at updated_at"
)

schema_ok=1
for tbl in users teams team_user servers server_settings; do
    if ! psql_ro -c "SELECT 1 FROM $tbl LIMIT 1" >/dev/null 2>&1; then
        printf '  Schema:           MISSING table %s\n' "$tbl"
        schema_ok=0
        continue
    fi
    missing_cols=""
    for col in ${REQUIRED_COLS[$tbl]}; do
        # Quote `user` since it's a reserved word in postgres
        if [[ "$col" == "user" ]]; then col_q='"user"'; else col_q="$col"; fi
        if ! psql_ro -c "SELECT $col_q FROM $tbl LIMIT 0" >/dev/null 2>&1; then
            missing_cols+=" $col"
        fi
    done
    if [[ -n "$missing_cols" ]]; then
        printf '  Schema:           %s missing columns:%s\n' "$tbl" "$missing_cols"
        schema_ok=0
    fi
done

if (( schema_ok )); then
    printf '  Schema:           OK — all required columns present across 5 tables\n'
else
    echo
    echo "ERROR: Coolify schema does not match what this script expects." >&2
    echo "Likely cause: Coolify was upgraded and renamed/removed columns. Run" >&2
    echo "with --check-schema to inspect the current layout, then update this" >&2
    echo "script's REQUIRED_COLS map + INSERTs to match." >&2
    exit 3
fi

echo "==================================================================="

# ---- Generate a placeholder bcrypt hash (via PHP in the coolify container)
# Users we create authenticate via OAuth; the password column exists in Laravel's
# users table (nullable per current Coolify schema, but seed a random hash to be
# safe against schema tightening AND to ensure the email/password login form can
# never succeed for these rows).
PLACEHOLDER_HASH=$(docker exec coolify php -r 'echo password_hash(bin2hex(random_bytes(32)), PASSWORD_BCRYPT);' 2>/dev/null || true)
if [[ -z "$PLACEHOLDER_HASH" ]]; then
    echo "ERROR: could not generate bcrypt hash via the 'coolify' container." >&2
    echo "Is the coolify container running? Try: docker ps | grep '^coolify'" >&2
    echo "Aborting — refusing to insert rows without a valid password hash." >&2
    exit 3
fi

# ---- Generate a Laravel-encrypted placeholder for server_settings.sentinel_token
# server_settings.sentinel_token has a Laravel 'encrypted' cast — plaintext or NULL
# both cause the server-show page to 500. Plaintext throws DecryptException at
# model load (fails cipher validation); NULL causes TypeError on the non-nullable
# public string $sentinelToken assignment in App\Livewire\Server\Show::syncData().
# handleError swallows both silently, mount bails, view crashes on unset Collection.
# So: encrypt a real placeholder via Laravel's own Crypt facade, keyed by APP_KEY.
ENC_SENTINEL_TOKEN=$(docker exec coolify php artisan tinker --execute="echo \Illuminate\Support\Facades\Crypt::encryptString('placeholder-not-used-by-team-server');" 2>/dev/null | tr -d '[:space:]')
if [[ -z "$ENC_SENTINEL_TOKEN" || ${#ENC_SENTINEL_TOKEN} -lt 100 ]]; then
    echo "ERROR: could not generate encrypted sentinel_token via 'coolify' container." >&2
    echo "  Expected a >=100-char Laravel Crypt payload; got: '${ENC_SENTINEL_TOKEN:0:60}...'" >&2
    echo "Aborting — refusing to insert rows without a valid encrypted placeholder." >&2
    exit 3
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

# ---- Load existing state so we can compute a per-row plan ---------------
# Newline-delimited lists of keys currently in the DB. Grep-based lookups
# below avoid a docker exec per row (30 rows would be 30 * 5 = 150 exec calls).
EXISTING_EMAILS=$(psql_ro -c "SELECT email FROM users;")
EXISTING_TEAMS=$(psql_ro -c "SELECT name FROM teams;")
# Encode team+user pivot as "team_name<TAB>email"
EXISTING_PIVOTS=$(psql_ro -c "SELECT t.name || E'\t' || u.email FROM team_user tu JOIN teams t ON t.id = tu.team_id JOIN users u ON u.id = tu.user_id;")
EXISTING_MLCAP_SERVER_TEAMS=$(psql_ro -c "SELECT t.name FROM servers s JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")
EXISTING_SERVER_SETTINGS_TEAMS=$(psql_ro -c "SELECT t.name FROM server_settings ss JOIN servers s ON s.id = ss.server_id JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")

# ---- Build SQL + plan in one pass ---------------------------------------
# One transactional batch. Emits five sections per row (user / team / pivot /
# server / server_settings), each guarded by NOT EXISTS or ON CONFLICT so
# re-runs are no-ops.
SQL_FILE=$(mktemp -t provision-teams.XXXXXX.sql)
PLAN_FILE=$(mktemp -t provision-teams.XXXXXX.plan)
trap 'rm -f "$SQL_FILE" "$PLAN_FILE"' EXIT

# Plan counters. Bumped as we iterate.
plan_new_users=0;     plan_exist_users=0
plan_new_teams=0;     plan_exist_teams=0
plan_new_pivots=0;    plan_exist_pivots=0
plan_new_servers=0;   plan_exist_servers=0
plan_new_settings=0;  plan_exist_settings=0
plan_data_rows=0  # non-blank, non-comment rows

# Helper: fixed-string exact-line grep against a $'\n'-separated list
has_line() { grep -qxF -- "$2" <<<"$1"; }

{
    echo "BEGIN;"
    echo "-- Generated by provision-teams.sh from $ROSTER on $(date -u +%FT%TZ)"
    echo

    row_num=1
    # Process substitution rather than pipe so `exit N` from validation aborts the
    # whole script (piped `while` runs in a subshell — `exit` only kills the subshell).
    while IFS= read -r line || [[ -n "$line" ]]; do
        row_num=$((row_num + 1))
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        line=${line%$'\r'}
        IFS=',' read -r -a F <<<"$line"

        team_name=${F[${COL_IDX[team_name]}]}
        email_raw=${F[${COL_IDX[email]}]}
        name=${F[${COL_IDX[name]}]}
        # tolerate missing github_username column
        gh=""
        [[ -n "${COL_IDX[github_username]+set}" ]] && gh=${F[${COL_IDX[github_username]}]:-}

        # Trim + lowercase (bash-native; xargs would choke on apostrophes).
        email=$(trim "$email_raw")
        email=${email,,}
        team_name=$(trim "$team_name")
        name=$(trim "$name")

        # Reject rows with empty required fields — silent inserts of '' would be
        # very hard to debug later, and the users.email unique constraint would
        # only surface the second bad row.
        if [[ -z "$email" || -z "$team_name" || -z "$name" ]]; then
            echo "ERROR: row $row_num has empty required field (team_name='$team_name' email='$email' name='$name')" >&2
            echo "Fix the CSV and re-run." >&2
            exit 4
        fi

        plan_data_rows=$((plan_data_rows + 1))

        # Compute per-row plan by checking existing state loaded above.
        # NOTE: this reflects DB state at script start. If two rows in the CSV
        # target the same NEW team, the second row will still show 'CREATE'
        # in the plan even though the SQL guards it with NOT EXISTS. That's
        # a display quirk, not a correctness issue.
        if has_line "$EXISTING_EMAILS" "$email"; then
            row_user="EXISTS"; plan_exist_users=$((plan_exist_users + 1))
        else
            row_user="CREATE"; plan_new_users=$((plan_new_users + 1))
        fi
        if has_line "$EXISTING_TEAMS" "$team_name"; then
            row_team="EXISTS"; plan_exist_teams=$((plan_exist_teams + 1))
        else
            row_team="CREATE"; plan_new_teams=$((plan_new_teams + 1))
        fi
        if has_line "$EXISTING_PIVOTS" "${team_name}"$'\t'"${email}"; then
            row_pivot="EXISTS"; plan_exist_pivots=$((plan_exist_pivots + 1))
        else
            row_pivot="CREATE"; plan_new_pivots=$((plan_new_pivots + 1))
        fi
        if has_line "$EXISTING_MLCAP_SERVER_TEAMS" "$team_name"; then
            row_server="EXISTS"; plan_exist_servers=$((plan_exist_servers + 1))
        else
            row_server="CREATE"; plan_new_servers=$((plan_new_servers + 1))
        fi
        if has_line "$EXISTING_SERVER_SETTINGS_TEAMS" "$team_name"; then
            row_settings="EXISTS"; plan_exist_settings=$((plan_exist_settings + 1))
        else
            row_settings="CREATE"; plan_new_settings=$((plan_new_settings + 1))
        fi

        # Write plan line to file; will print all at once later.
        printf '  Row %-3d %-40s %-30s  users:%s  teams:%s  pivot:%s  server:%s  settings:%s\n' \
            "$row_num" "$team_name" "<$email>" \
            "$row_user" "$row_team" "$row_pivot" "$row_server" "$row_settings" \
            >>"$PLAN_FILE"

        # SQL escape — double single quotes
        e_email=${email//\'/\'\'}
        e_team_name=${team_name//\'/\'\'}
        e_name=${name//\'/\'\'}
        e_gh=${gh//\'/\'\'}

        # Short unique uuid for the server row (Coolify format: 24 lowercase alnum)
        server_uuid=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 24)

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

-- Server 'ml-capstone' for team $team_name — abstracted from physical host so
-- we can move it later. Idempotent on team_id + name; ignores soft-deletes.
-- proxy '{"type":"NONE"}' declares 'no proxy managed by this server row' —
-- team servers all share the Root Team's Traefik (coolify-proxy container), so
-- there IS no per-team proxy to manage. Without this the server-show page 500s
-- because Coolify's view calls methods on a null proxy config object.
INSERT INTO servers (uuid, name, description, ip, port, "user", team_id, private_key_id, proxy, sentinel_updated_at, created_at, updated_at)
SELECT '$server_uuid', 'ml-capstone', 'Provisioned by provision-teams.sh for $e_team_name', 'host.docker.internal', 22, 'root', t.id, 0, '{"type":"NONE"}'::json, NOW(), NOW(), NOW()
FROM teams t
WHERE t.name = '$e_team_name'
  AND NOT EXISTS (SELECT 1 FROM servers s WHERE s.team_id = t.id AND s.name = 'ml-capstone' AND s.deleted_at IS NULL);

-- server_settings row for the server we just may have inserted. Multiple things
-- must be right here or the server-show page 500s in creative ways:
--   * is_reachable/is_usable: dashboard reads these; NULL causes 500.
--   * sentinel_token: Laravel 'encrypted' cast. NULL crashes syncData's
--     assignment to public string \$sentinelToken (TypeError). Plaintext
--     crashes model load (DecryptException). Only VALID Laravel Crypt
--     ciphertext works — we generated one via docker exec above.
--   * is_sentinel_enabled=false: we're not running per-team sentinel agents.
INSERT INTO server_settings (server_id, is_reachable, is_usable, is_sentinel_enabled, sentinel_token, created_at, updated_at)
SELECT s.id, true, true, false, '$ENC_SENTINEL_TOKEN', NOW(), NOW()
FROM servers s
JOIN teams t ON t.id = s.team_id
WHERE t.name = '$e_team_name'
  AND s.name = 'ml-capstone'
  AND s.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM server_settings ss WHERE ss.server_id = s.id);

SQL
    done < <(tail -n +2 "$ROSTER")

    echo "COMMIT;"
} >"$SQL_FILE"

echo
echo "============================== PLAN ==============================="
echo "  Roster:    $ROSTER"
echo "  Data rows: $plan_data_rows (excluding header + blank/#-commented lines)"
echo "  Target:    docker exec $COOLIFY_DB_CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME"
echo "  Mode:      $([[ $APPLY == 1 ]] && echo "APPLY" || echo "dry-run (use --apply to execute)")"
echo
echo "  Per-row plan:"
if [[ -s "$PLAN_FILE" ]]; then
    cat "$PLAN_FILE"
else
    echo "  (no data rows)"
fi
echo
echo "  Rollup:                            CREATE    EXISTS"
printf '    users                              %5d     %5d\n' "$plan_new_users"    "$plan_exist_users"
printf '    teams                              %5d     %5d\n' "$plan_new_teams"    "$plan_exist_teams"
printf '    team_user pivots                   %5d     %5d\n' "$plan_new_pivots"   "$plan_exist_pivots"
printf '    servers (name=ml-capstone)         %5d     %5d\n' "$plan_new_servers"  "$plan_exist_servers"
printf '    server_settings                    %5d     %5d\n' "$plan_new_settings" "$plan_exist_settings"
echo
total_new=$((plan_new_users + plan_new_teams + plan_new_pivots + plan_new_servers + plan_new_settings))
if (( total_new == 0 )); then
    echo "  Effect:    NO-OP (roster is entirely a subset of current DB state)"
else
    echo "  Effect:    $total_new new row(s) will be INSERTed."
fi
echo "==================================================================="
echo

if (( SHOW_SQL )); then
    echo "--- SQL to execute (from $SQL_FILE) ---"
    cat "$SQL_FILE"
    echo "--- end SQL ---"
    echo
fi

if (( ! APPLY )); then
    echo "READY: preflight passed, plan generated, no changes made to the database."
    if (( total_new == 0 )); then
        echo "        Roster is already fully represented — running --apply would be a no-op."
    else
        echo "        Running --apply will INSERT $total_new row(s) in one transaction."
    fi
    if (( ! SHOW_SQL )); then
        echo "        Full SQL is at $SQL_FILE (pass --show-sql to print it here)."
    fi
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

# ---- Verify --------------------------------------------------------------
# Re-load DB state and confirm every planned CREATE actually materialized.
# We don't just check counts; we check that the specific keys from the CSV
# are now in the corresponding tables.
echo
echo "============================= VERIFY =============================="

AFTER_EMAILS=$(psql_ro -c "SELECT email FROM users;")
AFTER_TEAMS=$(psql_ro -c "SELECT name FROM teams;")
AFTER_PIVOTS=$(psql_ro -c "SELECT t.name || E'\t' || u.email FROM team_user tu JOIN teams t ON t.id = tu.team_id JOIN users u ON u.id = tu.user_id;")
AFTER_MLCAP_SERVERS=$(psql_ro -c "SELECT t.name FROM servers s JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")
AFTER_SETTINGS=$(psql_ro -c "SELECT t.name FROM server_settings ss JOIN servers s ON s.id = ss.server_id JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")

verify_fails=0
row_num=1
while IFS= read -r line || [[ -n "$line" ]]; do
    row_num=$((row_num + 1))
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    line=${line%$'\r'}
    IFS=',' read -r -a F <<<"$line"
    team_name=$(trim "${F[${COL_IDX[team_name]}]}")
    email=$(trim "${F[${COL_IDX[email]}]}")
    email=${email,,}
    [[ -z "$team_name" || -z "$email" ]] && continue

    missing=""
    has_line "$AFTER_EMAILS"          "$email"                                    || missing+=" users"
    has_line "$AFTER_TEAMS"           "$team_name"                                || missing+=" teams"
    has_line "$AFTER_PIVOTS"          "${team_name}"$'\t'"${email}"               || missing+=" pivot"
    has_line "$AFTER_MLCAP_SERVERS"   "$team_name"                                || missing+=" server"
    has_line "$AFTER_SETTINGS"        "$team_name"                                || missing+=" settings"

    if [[ -z "$missing" ]]; then
        printf '  Row %-3d ✓  %-40s <%s>\n' "$row_num" "$team_name" "$email"
    else
        printf '  Row %-3d ✗  %-40s <%s>  MISSING:%s\n' "$row_num" "$team_name" "$email" "$missing"
        verify_fails=$((verify_fails + 1))
    fi
done < <(tail -n +2 "$ROSTER")

echo "==================================================================="
if (( verify_fails > 0 )); then
    echo "VERIFY FAILED — $verify_fails row(s) missing expected state. Investigate." >&2
    exit 5
fi
echo
echo "SUCCESS: $plan_data_rows row(s) processed, $total_new new DB row(s) inserted, all verified."
echo "Students with rows in 'users' can now sign in via GitHub OAuth using the email"
echo "in their row. Coolify will link the account on first login."
