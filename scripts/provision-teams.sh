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
#   ./provision-teams.sh --observer <email>     # add this user as admin of every
#                                               # team so they can see + help in UI.
#                                               # Falls back to $OPERATOR_EMAIL env var.
#                                               # Set OPERATOR_EMAIL in your rigel shell
#                                               # profile to make this automatic.
#   ./provision-teams.sh --class-password <pw>  # set Coolify password for every user.
#                                               # Needed because Coolify's UI destructive-
#                                               # action modals prompt for a password even
#                                               # for OAuth-authenticated sessions. Falls
#                                               # back to $CLASS_PASSWORD env var. Document
#                                               # the value you pick in student-guide's
#                                               # Setup Step 2 so students know it.
#   ./provision-teams.sh --check-schema         # dump all 6 tables' schemas, exit
#   ./provision-teams.sh --show-sql             # also print the raw SQL (default: plan only)
#   ./provision-teams.sh -h                     # this help
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

APPLY=0
CHECK_SCHEMA=0
SHOW_SQL=0
ROSTER=""
# Observer: an admin who gets added to every provisioned team so they can see
# and help in the UI. Set via --observer <email> or OPERATOR_EMAIL env var.
# Silently no-op if unset (backward compatible).
OBSERVER_EMAIL="${OPERATOR_EMAIL:-}"

# Class-wide password for provisioned users. Coolify's UI destructive-action
# modals (Delete Application, Delete Project, etc.) prompt for the user's
# password even when the session was OAuth-authenticated. OAuth users have no
# password unless we seed one — and Coolify's "Change Password" flow requires
# a current password to set a new one, so students can't self-serve. The
# password-reset-via-email flow needs working SMTP (currently broken on
# ml-capstone). Setting a known class-wide password here unblocks the modals
# without changing the GitHub OAuth login path (both auth methods remain
# available; students still click "Sign in with GitHub" as before).
#
# Set via --class-password <value> or CLASS_PASSWORD env var. Default is a
# placeholder; a loud warning is printed if unchanged.
CLASS_PASSWORD="${CLASS_PASSWORD:-capstone-changeme}"

# Coolify major.minor versions this script has been proven against. New minors
# are likely fine but flag them so the operator can decide. Space-separated
# list; each entry matches "<entry>.*" (e.g. "4.2" matches 4.2.0, 4.2.7, ...).
# When Coolify ships a new minor, re-run with --check-schema, diff against
# REQUIRED_COLS below, and append the new minor here if compatible.
KNOWN_GOOD_MAJOR_MINORS="4.2 4.3"

# ---- Argument parsing ---------------------------------------------------
usage() { common_usage "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)         APPLY=1; shift ;;
        --roster)        ROSTER="$2"; shift 2 ;;
        --observer)      OBSERVER_EMAIL="$2"; shift 2 ;;
        --class-password) CLASS_PASSWORD="$2"; shift 2 ;;
        --check-schema)  CHECK_SCHEMA=1; shift ;;
        --show-sql)      SHOW_SQL=1; shift ;;
        -h|--help)       usage ;;
        *) echo "Unknown option: $1" >&2; echo "Run with --help." >&2; exit 2 ;;
    esac
done

# Normalize + validate observer email if provided.
if [[ -n "$OBSERVER_EMAIL" ]]; then
    OBSERVER_EMAIL="${OBSERVER_EMAIL,,}"
    if [[ ! "$OBSERVER_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        echo "ERROR: --observer email '$OBSERVER_EMAIL' doesn't look like a valid address." >&2
        exit 2
    fi
fi

# ---- Postgres helper ----------------------------------------------------
# psql invocations run inside the coolify-db container. -A: unaligned output,
# -t: tuples only, -F: field separator (for parsing).
psql_ro()  { docker exec -i "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -At -F$'\t' "$@"; }
psql_exec() { docker exec -i "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -v ON_ERROR_STOP=1 "$@"; }

# ---- Sanity: DB reachable ----------------------------------------------
# Needed for both --check-schema and the normal path.
if ! docker exec "$COOLIFY_DB_CONTAINER" pg_isready -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" >/dev/null 2>&1; then
    echo "Cannot reach Postgres in container '$COOLIFY_DB_CONTAINER'." >&2
    echo "Is Coolify running? Try: docker ps | grep coolify-db" >&2
    exit 3
fi

# ---- Preflight: Coolify version ----------------------------------------
# Print version + known-good status FIRST — matters for both --check-schema
# (so operator sees which version they're auditing) and the normal path.
common_banner "PREFLIGHT"

COOLIFY_IMAGE=$(docker inspect coolify --format '{{.Config.Image}}' 2>/dev/null || echo "")
COOLIFY_VERSION="${COOLIFY_IMAGE##*:}"
if [[ -z "$COOLIFY_VERSION" ]]; then
    COOLIFY_VERSION="unknown"
fi

version_status="untested"
case "$COOLIFY_VERSION" in
    latest) version_status="floating tag — verify the running version elsewhere" ;;
    *)
        for kg in $KNOWN_GOOD_MAJOR_MINORS; do
            case "$COOLIFY_VERSION" in
                ${kg}.*) version_status="known-good"; break ;;
            esac
        done
        ;;
esac
printf '  Coolify version:  %s (%s; script proven against %s)\n' \
    "$COOLIFY_VERSION" "$version_status" "${KNOWN_GOOD_MAJOR_MINORS// /.x, }.x"

# ---- --check-schema: dump tables and exit ------------------------------
# Runs AFTER the version banner so the operator sees which Coolify version
# they're auditing. Dumps every table this script writes to, so an operator
# can diff against REQUIRED_COLS after a Coolify upgrade.
if (( CHECK_SCHEMA )); then
    common_banner_end
    for tbl in users teams team_user servers server_settings standalone_dockers; do
        echo
        echo "=== $tbl ==="
        docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -c "\d $tbl"
    done
    exit 0
fi

# ---- Pick roster (normal path only) ------------------------------------
ROSTER=$(common_pick_roster "$ROSTER") || exit $?
[[ -r "$ROSTER" ]] || { echo "Cannot read $ROSTER" >&2; exit 2; }

# ---- Schema fingerprint check ------------------------------------------

# Check every table + every column we're about to INSERT into. If Coolify
# renames or removes any of these on upgrade, abort loudly here rather than
# emitting a broken SQL batch that partially applies.
declare -A REQUIRED_COLS=(
  [users]="email name password email_verified_at created_at updated_at"
  [teams]="name description personal_team created_at updated_at"
  [team_user]="team_id user_id role created_at updated_at"
  [servers]="uuid name description ip port user team_id private_key_id proxy sentinel_updated_at deleted_at created_at updated_at"
  [server_settings]="server_id is_reachable is_usable is_sentinel_enabled sentinel_token created_at updated_at"
  [standalone_dockers]="uuid name network server_id created_at updated_at"
)

schema_ok=1
for tbl in users teams team_user servers server_settings standalone_dockers; do
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
    printf '  Schema:           OK — all required columns present across %d tables\n' "${#REQUIRED_COLS[@]}"
else
    echo
    echo "ERROR: Coolify schema does not match what this script expects." >&2
    echo "Likely cause: Coolify was upgraded and renamed/removed columns. Run" >&2
    echo "with --check-schema to inspect the current layout, then update this" >&2
    echo "script's REQUIRED_COLS map + INSERTs to match." >&2
    exit 3
fi

common_banner_end

# ---- Bcrypt-hash the class-wide password via PHP in the coolify container --
# See the CLASS_PASSWORD comment above the argument parser for why we seed a
# known password rather than a random placeholder. Warn loudly if the default
# is still in use so an instructor doesn't accidentally ship it to students.
if [[ "$CLASS_PASSWORD" == "capstone-changeme" ]]; then
    echo "WARNING: using default class password 'capstone-changeme'." >&2
    echo "         Override with --class-password <value> or CLASS_PASSWORD env var." >&2
    echo "         The default is intended as an obvious placeholder, not to ship." >&2
fi

# PHP-single-quote-safe escape of the password (' -> \', \ -> \\).
php_esc_password=$(printf %s "$CLASS_PASSWORD" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g")
CLASS_PASSWORD_HASH=$(docker exec coolify php -r "echo password_hash('$php_esc_password', PASSWORD_BCRYPT);" 2>/dev/null || true)
if [[ -z "$CLASS_PASSWORD_HASH" ]]; then
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

# ---- Resolve observer (if provided) -------------------------------------
# The observer becomes an admin of every team we provision so they can see
# and help in the UI without the manual DB-dance. Look up their user_id
# once; skip loudly if the email isn't in users yet.
OBSERVER_USER_ID=""
if [[ -n "$OBSERVER_EMAIL" ]]; then
    esc_obs=${OBSERVER_EMAIL//\'/\'\'}
    OBSERVER_USER_ID=$(psql_ro -c "SELECT id FROM users WHERE email = '$esc_obs';" | head -n1)
    if [[ -z "$OBSERVER_USER_ID" ]]; then
        echo "ERROR: --observer email '$OBSERVER_EMAIL' not found in Coolify's users table." >&2
        echo "Sign in to Coolify at least once with that email (GitHub OAuth) so a users" >&2
        echo "row exists, then re-run. Aborting to avoid silent no-op." >&2
        exit 3
    fi
    printf '  Observer:         %s (user_id=%s) will be added as admin of every team\n' \
        "$OBSERVER_EMAIL" "$OBSERVER_USER_ID"
fi

# ---- Announce the class password (once, at plan time) --------------------
# Repeated so it's hard to miss when reviewing the plan output — instructors
# need to distribute this to students.
printf '  Class password:   %s   (users can type this into Coolify UI destructive-action modals)\n' \
    "$CLASS_PASSWORD"

# ---- Read + validate CSV ------------------------------------------------
# Parse header, verify required columns present.
declare -A COL_IDX=()
common_csv_parse_header COL_IDX "$ROSTER"
for required in team_name email name; do
    common_csv_require_column COL_IDX "$required" || exit 2
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
EXISTING_DESTINATION_TEAMS=$(psql_ro -c "SELECT t.name FROM standalone_dockers sd JOIN servers s ON s.id = sd.server_id JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")

# ---- Build SQL-escaped list of roster emails (for the cleanup phase) ----
# Coolify auto-creates a personal team on every OAuth signup. If the user is
# already in our roster, that auto-created team is a redundant "No servers
# found" trap page. We'll delete such teams later, but need the emails now.
ROSTER_EMAILS_SQL=""
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    line=${line%$'\r'}
    IFS=',' read -r -a F <<<"$line"
    e=$(common_trim "${F[${COL_IDX[email]}]}")
    e=${e,,}
    [[ -z "$e" ]] && continue
    # SQL-escape single quotes
    esc_e=${e//\'/\'\'}
    [[ -n "$ROSTER_EMAILS_SQL" ]] && ROSTER_EMAILS_SQL+=","
    ROSTER_EMAILS_SQL+="'$esc_e'"
done < <(tail -n +2 "$ROSTER")

# Query for redundant personal teams for our roster users, right now.
# (The main INSERTs below don't touch personal_team=true rows, so this list
# stays accurate through the transaction.)
if [[ -n "$ROSTER_EMAILS_SQL" ]]; then
    CLEANUP_TEAMS=$(psql_ro -c "
      SELECT DISTINCT t.id || E'\t' || t.name || E'\t' || u.email
      FROM teams t
      JOIN team_user tu ON tu.team_id = t.id
      JOIN users u ON u.id = tu.user_id
      WHERE t.personal_team = true
        AND u.email IN ($ROSTER_EMAILS_SQL)
        AND NOT EXISTS (SELECT 1 FROM servers s WHERE s.team_id = t.id AND s.deleted_at IS NULL);
    ")
else
    CLEANUP_TEAMS=""
fi
plan_cleanup_teams=0
[[ -n "$CLEANUP_TEAMS" ]] && plan_cleanup_teams=$(printf '%s\n' "$CLEANUP_TEAMS" | wc -l | tr -d ' ')

# ---- Build SQL + plan in one pass ---------------------------------------
# One transactional batch. Emits six sections per row (user / team / pivot /
# server / server_settings / standalone_dockers), each guarded by NOT EXISTS
# or ON CONFLICT so re-runs are no-ops.
SQL_FILE=$(mktemp -t provision-teams.XXXXXX.sql)
PLAN_FILE=$(mktemp -t provision-teams.XXXXXX.plan)
trap 'rm -f "$SQL_FILE" "$PLAN_FILE"' EXIT

# Plan counters. Bumped as we iterate.
plan_new_users=0;         plan_exist_users=0
plan_new_teams=0;         plan_exist_teams=0
plan_new_pivots=0;        plan_exist_pivots=0
plan_new_servers=0;       plan_exist_servers=0
plan_new_settings=0;      plan_exist_settings=0
plan_new_destinations=0;  plan_exist_destinations=0
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
        email=$(common_trim "$email_raw")
        email=${email,,}
        team_name=$(common_trim "$team_name")
        name=$(common_trim "$name")

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
        if has_line "$EXISTING_DESTINATION_TEAMS" "$team_name"; then
            row_dest="EXISTS"; plan_exist_destinations=$((plan_exist_destinations + 1))
        else
            row_dest="CREATE"; plan_new_destinations=$((plan_new_destinations + 1))
        fi

        # Write plan line to file; will print all at once later.
        printf '  Row %-3d %-40s %-30s  users:%s  teams:%s  pivot:%s  server:%s  settings:%s  dest:%s\n' \
            "$row_num" "$team_name" "<$email>" \
            "$row_user" "$row_team" "$row_pivot" "$row_server" "$row_settings" "$row_dest" \
            >>"$PLAN_FILE"

        # SQL escape — double single quotes
        e_email=${email//\'/\'\'}
        e_team_name=${team_name//\'/\'\'}
        e_name=${name//\'/\'\'}
        e_gh=${gh//\'/\'\'}

        # Short unique uuids (Coolify format: 24 lowercase alnum). One per new row.
        server_uuid=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 24)
        dest_uuid=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 24)

        cat <<SQL
-- Row: team=$team_name, user=$email
-- ON CONFLICT UPDATE (not DO NOTHING) so re-running the script with a new
-- --class-password rotates the password for existing users too. Students
-- who set their own password via the UI would lose that override on re-run;
-- document the tradeoff or coordinate class-wide reruns accordingly.
INSERT INTO users (name, email, email_verified_at, password, created_at, updated_at)
VALUES ('$e_name', '$e_email', NOW(), '$CLASS_PASSWORD_HASH', NOW(), NOW())
ON CONFLICT (email) DO UPDATE
    SET password   = EXCLUDED.password,
        updated_at = NOW();

INSERT INTO teams (name, description, personal_team, created_at, updated_at)
SELECT '$e_team_name', 'Provisioned by provision-teams.sh${e_gh:+ (github=$e_gh)}', false, NOW(), NOW()
WHERE NOT EXISTS (SELECT 1 FROM teams WHERE name = '$e_team_name');

INSERT INTO team_user (team_id, user_id, role, created_at, updated_at)
SELECT t.id, u.id, 'admin', NOW(), NOW()
FROM teams t, users u
WHERE t.name = '$e_team_name' AND u.email = '$e_email'
ON CONFLICT (team_id, user_id) DO NOTHING;
${OBSERVER_USER_ID:+
-- Observer ($OBSERVER_EMAIL) as admin of this team so they can see + help in UI
INSERT INTO team_user (team_id, user_id, role, created_at, updated_at)
SELECT t.id, $OBSERVER_USER_ID, 'admin', NOW(), NOW()
FROM teams t WHERE t.name = '$e_team_name'
ON CONFLICT (team_id, user_id) DO NOTHING;
}

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

-- Standalone Docker destination for the team's server. Coolify's + Add Resource
-- flow requires at least one destination on the target server; without it the
-- user sees "Select a destination" with no options and cannot create Applications.
-- We share the 'coolify' network (same as Root Team's default) — all team servers
-- run on the same physical box, so a separate docker network per team would add
-- complexity without meaningful isolation. Application-level isolation via
-- team_id + labels is what actually separates teams' apps.
INSERT INTO standalone_dockers (uuid, name, network, server_id, created_at, updated_at)
SELECT '$dest_uuid', 'coolify', 'coolify', s.id, NOW(), NOW()
FROM servers s
JOIN teams t ON t.id = s.team_id
WHERE t.name = '$e_team_name'
  AND s.name = 'ml-capstone'
  AND s.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM standalone_dockers sd WHERE sd.server_id = s.id);

SQL
    done < <(tail -n +2 "$ROSTER")

    # ---- Cleanup: delete redundant personal teams ------------------------
    # For any user in the roster who ALSO has a Coolify auto-created personal
    # team with zero servers, delete that personal team. Safe: the user still
    # has the script-provisioned team (which has a server), so Coolify's team
    # switcher will land them there on next request.
    if [[ -n "$CLEANUP_TEAMS" ]]; then
        # Extract just the ids (first tab-separated field)
        cleanup_ids=$(printf '%s\n' "$CLEANUP_TEAMS" | awk -F'\t' '{print $1}' | paste -sd, -)
        cat <<SQL

-- CLEANUP: delete $plan_cleanup_teams redundant personal team(s) for roster users
-- (Coolify auto-creates these on OAuth signup; they show 'No servers found'.)
DELETE FROM team_user WHERE team_id IN ($cleanup_ids);
DELETE FROM teams WHERE id IN ($cleanup_ids);
SQL
    fi

    echo "COMMIT;"
} >"$SQL_FILE"

common_banner "PLAN"
echo "  Roster:    $ROSTER"
echo "  Data rows: $plan_data_rows (excluding header + blank/#-commented lines)"
echo "  Target:    docker exec $COOLIFY_DB_CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME"
echo "  Mode:      $(common_mode_label "$APPLY")"
echo
echo "  Per-row plan:"
if [[ -s "$PLAN_FILE" ]]; then
    cat "$PLAN_FILE"
else
    echo "  (no data rows)"
fi
echo
echo "  Rollup:                            CREATE    EXISTS"
printf '    users                              %5d     %5d\n' "$plan_new_users"        "$plan_exist_users"
printf '    teams                              %5d     %5d\n' "$plan_new_teams"        "$plan_exist_teams"
printf '    team_user pivots                   %5d     %5d\n' "$plan_new_pivots"       "$plan_exist_pivots"
printf '    servers (name=ml-capstone)         %5d     %5d\n' "$plan_new_servers"      "$plan_exist_servers"
printf '    server_settings                    %5d     %5d\n' "$plan_new_settings"     "$plan_exist_settings"
printf '    standalone_dockers (destinations)  %5d     %5d\n' "$plan_new_destinations" "$plan_exist_destinations"
echo
if (( plan_cleanup_teams > 0 )); then
    echo "  Cleanup (will DELETE):"
    printf '    redundant personal teams          %6d       (auto-created by Coolify on OAuth signup; empty)\n' "$plan_cleanup_teams"
    printf '%s\n' "$CLEANUP_TEAMS" | awk -F'\t' '{printf "      - team id=%s \"%s\" (owned by %s)\n", $1, $2, $3}'
    echo
fi
total_new=$((plan_new_users + plan_new_teams + plan_new_pivots + plan_new_servers + plan_new_settings + plan_new_destinations))
if (( total_new == 0 && plan_cleanup_teams == 0 )); then
    echo "  Effect:    NO-OP (roster fully represented, no cleanup needed)"
else
    parts=""
    (( total_new > 0 )) && parts+="INSERT $total_new row(s)"
    (( plan_cleanup_teams > 0 )) && parts+="${parts:+ + }DELETE $plan_cleanup_teams redundant team(s)"
    echo "  Effect:    $parts, in one transaction."
fi
common_banner_end
echo

if (( SHOW_SQL )); then
    echo "--- SQL to execute (from $SQL_FILE) ---"
    cat "$SQL_FILE"
    echo "--- end SQL ---"
    echo
fi

if (( ! APPLY )); then
    echo "READY: preflight passed, plan generated, no changes made to the database."
    if (( total_new == 0 && plan_cleanup_teams == 0 )); then
        echo "        Roster is already fully represented and no cleanup needed — --apply would be a no-op."
    else
        (( total_new > 0 )) && echo "        Running --apply will INSERT $total_new row(s)."
        (( plan_cleanup_teams > 0 )) && echo "        Running --apply will also DELETE $plan_cleanup_teams redundant personal team(s)."
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
common_banner "VERIFY"

AFTER_EMAILS=$(psql_ro -c "SELECT email FROM users;")
AFTER_TEAMS=$(psql_ro -c "SELECT name FROM teams;")
AFTER_PIVOTS=$(psql_ro -c "SELECT t.name || E'\t' || u.email FROM team_user tu JOIN teams t ON t.id = tu.team_id JOIN users u ON u.id = tu.user_id;")
AFTER_MLCAP_SERVERS=$(psql_ro -c "SELECT t.name FROM servers s JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")
AFTER_SETTINGS=$(psql_ro -c "SELECT t.name FROM server_settings ss JOIN servers s ON s.id = ss.server_id JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")
AFTER_DESTINATIONS=$(psql_ro -c "SELECT t.name FROM standalone_dockers sd JOIN servers s ON s.id = sd.server_id JOIN teams t ON t.id = s.team_id WHERE s.name = 'ml-capstone' AND s.deleted_at IS NULL;")

verify_fails=0
row_num=1
while IFS= read -r line || [[ -n "$line" ]]; do
    row_num=$((row_num + 1))
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    line=${line%$'\r'}
    IFS=',' read -r -a F <<<"$line"
    team_name=$(common_trim "${F[${COL_IDX[team_name]}]}")
    email=$(common_trim "${F[${COL_IDX[email]}]}")
    email=${email,,}
    [[ -z "$team_name" || -z "$email" ]] && continue

    missing=""
    has_line "$AFTER_EMAILS"          "$email"                                    || missing+=" users"
    has_line "$AFTER_TEAMS"           "$team_name"                                || missing+=" teams"
    has_line "$AFTER_PIVOTS"          "${team_name}"$'\t'"${email}"               || missing+=" pivot"
    has_line "$AFTER_MLCAP_SERVERS"   "$team_name"                                || missing+=" server"
    has_line "$AFTER_SETTINGS"        "$team_name"                                || missing+=" settings"
    has_line "$AFTER_DESTINATIONS"    "$team_name"                                || missing+=" destination"

    if [[ -z "$missing" ]]; then
        printf '  Row %-3d ✓  %-40s <%s>\n' "$row_num" "$team_name" "$email"
    else
        printf '  Row %-3d ✗  %-40s <%s>  MISSING:%s\n' "$row_num" "$team_name" "$email" "$missing"
        verify_fails=$((verify_fails + 1))
    fi
done < <(tail -n +2 "$ROSTER")

# Verify cleanup phase — no roster user should still own an empty personal team
if (( plan_cleanup_teams > 0 )); then
    STILL_REDUNDANT=$(psql_ro -c "
      SELECT DISTINCT t.id FROM teams t
      JOIN team_user tu ON tu.team_id = t.id
      JOIN users u ON u.id = tu.user_id
      WHERE t.personal_team = true
        AND u.email IN ($ROSTER_EMAILS_SQL)
        AND NOT EXISTS (SELECT 1 FROM servers s WHERE s.team_id = t.id AND s.deleted_at IS NULL);
    ")
    if [[ -n "$STILL_REDUNDANT" ]]; then
        n_still=$(printf '%s\n' "$STILL_REDUNDANT" | wc -l | tr -d ' ')
        printf '  Cleanup ✗  %d redundant personal team(s) still present after DELETE\n' "$n_still"
        verify_fails=$((verify_fails + 1))
    else
        printf '  Cleanup ✓  %d redundant personal team(s) removed\n' "$plan_cleanup_teams"
    fi
fi

common_banner_end
if (( verify_fails > 0 )); then
    echo "VERIFY FAILED — $verify_fails row(s) missing expected state. Investigate." >&2
    exit 5
fi
echo
summary_parts="$total_new new row(s) inserted"
(( plan_cleanup_teams > 0 )) && summary_parts+=", $plan_cleanup_teams redundant team(s) deleted"
echo "SUCCESS: $plan_data_rows roster row(s) processed, $summary_parts, all verified."
echo "Students with rows in 'users' can now sign in via GitHub OAuth using the email"
echo "in their row. Coolify will land them directly in their provisioned team."
