#!/usr/bin/env bash
# =============================================================================
# set-class-password.sh — Set or rotate the Coolify password for class accounts
#
# Why this exists separately from provision-teams.sh: that script's job is
# teams, and it happens to seed a password as a side effect. Rotating a
# credential is its own operation, with its own safety requirements, and
# should not require re-running a provisioning pass over the whole roster.
#
# Why a password exists at all: Coolify prompts for one on every destructive-
# action modal (Delete Application, Delete Project) even when the session came
# from GitHub OAuth, and Coolify's own "Change Password" flow needs a current
# password to set a new one. Students never need it to log in.
#
# HANDLING OF THE VALUE
#   - Never pass it on the command line. Anything in argv is visible to every
#     user on the box via `ps`. This script PROMPTS instead (silent read), or
#     reads $CLASS_PASSWORD, or generates one with --generate.
#   - Never written to disk. The bcrypt hash is computed inside the coolify
#     container and piped straight into psql over stdin; no temp SQL file.
#   - Never echoed back, except once by --generate so you can record it.
#   - Never commit it. This repository is public.
#
# SCOPE
#   By default, every email in the roster CSV. Narrow with --user, or widen
#   with --all. The instance root account (users.id = 0, normally the
#   instructor) is excluded unless you pass --include-root -- rotating it out
#   from under yourself is rarely what you want.
#
# Usage:
#   ./set-class-password.sh                     # dry-run, prompts, newest roster
#   ./set-class-password.sh --apply             # prompt, then rotate
#   ./set-class-password.sh --generate --apply  # generate, print once, rotate
#   ./set-class-password.sh --user a@b.edu --apply
#   ./set-class-password.sh --roster path.csv --apply
#   ./set-class-password.sh --all --apply       # every non-root Coolify user
#   ./set-class-password.sh --include-root      # also rotate users.id = 0
#   ./set-class-password.sh --verify            # check the current password,
#                                               # change nothing
#   ./set-class-password.sh -h                  # this help
#
# Run this ON RIGEL as a user in the docker group.
# =============================================================================

set -u

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

: "${COOLIFY_DB_CONTAINER:=coolify-db}"
: "${COOLIFY_DB_USER:=coolify}"
: "${COOLIFY_DB_NAME:=coolify}"
: "${COOLIFY_APP_CONTAINER:=coolify}"

APPLY=0
GENERATE=0
VERIFY_ONLY=0
ALL_USERS=0
INCLUDE_ROOT=0
ROSTER=""
ONE_USER=""

usage() { common_usage "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)        APPLY=1; shift ;;
        --generate)     GENERATE=1; shift ;;
        --verify)       VERIFY_ONLY=1; shift ;;
        --all)          ALL_USERS=1; shift ;;
        --include-root) INCLUDE_ROOT=1; shift ;;
        --roster)       ROSTER="$2"; shift 2 ;;
        --user)         ONE_USER="${2,,}"; shift 2 ;;
        -h|--help)      usage ;;
        *) echo "Unknown option: $1" >&2; echo "Run with --help." >&2; exit 2 ;;
    esac
done

psql_q() {
    docker exec -i "$COOLIFY_DB_CONTAINER" \
        psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -At -F'|' -c "$1"
}

common_banner "set-class-password.sh"

# ---- preflight ----------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx "$COOLIFY_DB_CONTAINER"; then
    echo "ERROR: container '$COOLIFY_DB_CONTAINER' is not running here." >&2
    echo "       This script must run on the Coolify host." >&2
    exit 3
fi
if ! docker ps --format '{{.Names}}' | grep -qx "$COOLIFY_APP_CONTAINER"; then
    echo "ERROR: container '$COOLIFY_APP_CONTAINER' is not running here." >&2
    echo "       Needed to compute the bcrypt hash with Coolify's own PHP." >&2
    exit 3
fi

# ---- who is in scope ----------------------------------------------------
declare -a TARGETS=()
if [[ -n "$ONE_USER" ]]; then
    SCOPE="single user: $ONE_USER"
    mapfile -t TARGETS < <(psql_q "SELECT email FROM users WHERE lower(email) = '${ONE_USER//\'/\'\'}';")
elif [[ $ALL_USERS -eq 1 ]]; then
    SCOPE="every Coolify user"
    mapfile -t TARGETS < <(psql_q "SELECT email FROM users ORDER BY email;")
else
    ROSTER=$(common_pick_roster "$ROSTER") || exit $?
    SCOPE="roster: $ROSTER"
    declare -a WANT=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        email=$(printf '%s' "$line" | cut -d, -f2)
        email=$(common_trim "${email,,}")
        [[ -z "$email" || "$email" == "email" ]] && continue
        WANT+=("$email")
    done < "$ROSTER"
    # Dedupe: a student appears once per team they belong to.
    mapfile -t WANT < <(printf '%s\n' "${WANT[@]}" | sort -u)
    for e in "${WANT[@]}"; do
        found=$(psql_q "SELECT email FROM users WHERE lower(email) = '${e//\'/\'\'}';")
        if [[ -n "$found" ]]; then TARGETS+=("$found"); else MISSING+=("$e"); fi
    done
fi

# Root account is excluded by default.
if [[ $INCLUDE_ROOT -eq 0 ]]; then
    root_email=$(psql_q "SELECT email FROM users WHERE id = 0;")
    if [[ -n "$root_email" ]]; then
        declare -a KEPT=()
        for e in "${TARGETS[@]}"; do
            [[ "${e,,}" == "${root_email,,}" ]] || KEPT+=("$e")
        done
        if [[ ${#KEPT[@]} -ne ${#TARGETS[@]} ]]; then
            echo "  Excluding root account $root_email (pass --include-root to rotate it too)"
        fi
        TARGETS=("${KEPT[@]:-}")
    fi
fi
# Drop any empty element left by the ${KEPT[@]:-} guard on an empty array.
declare -a CLEAN=()
for e in "${TARGETS[@]:-}"; do [[ -n "$e" ]] && CLEAN+=("$e"); done
TARGETS=("${CLEAN[@]:-}")

echo "  Scope:            $SCOPE"
echo "  Accounts matched: ${#TARGETS[@]}"
if [[ -n "${MISSING+x}" && ${#MISSING[@]} -gt 0 ]]; then
    echo "  On roster but NOT in Coolify (${#MISSING[@]}): ${MISSING[*]}"
    echo "    -> these have never signed in; provision-teams.sh creates them."
fi
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo; echo "Nothing to do."; exit 0
fi

# ---- obtain the password ------------------------------------------------
PASSWORD=""
if [[ $GENERATE -eq 1 ]]; then
    # Ambiguous characters removed: this gets typed by hand into a modal.
    PASSWORD=$(LC_ALL=C tr -dc 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789' \
                 < /dev/urandom | head -c 16)
elif [[ -n "${CLASS_PASSWORD:-}" ]]; then
    PASSWORD="$CLASS_PASSWORD"
    echo "  Password source:  \$CLASS_PASSWORD environment variable"
else
    # Prompt rather than take it in argv, which `ps` would expose.
    printf '  New class password (input hidden): ' >&2
    read -rs PASSWORD; printf '\n' >&2
    if [[ $VERIFY_ONLY -eq 0 ]]; then
        printf '  Confirm:                           ' >&2
        read -rs CONFIRM; printf '\n' >&2
        if [[ "$PASSWORD" != "$CONFIRM" ]]; then
            echo "ERROR: passwords do not match." >&2; exit 2
        fi
    fi
fi
if [[ -z "$PASSWORD" ]]; then
    echo "ERROR: empty password." >&2; exit 2
fi
# Refuse to SET the published placeholder. Checking for it is fine, and is in
# fact the main thing you would want to audit.
if [[ "$PASSWORD" == "capstone-changeme" && $VERIFY_ONLY -eq 0 ]]; then
    echo "ERROR: that is the placeholder published in this public repo." >&2
    echo "       Pick something else." >&2
    exit 2
fi

# ---- verify mode: check, change nothing ---------------------------------
# The password is passed to PHP through the environment, not argv.
php_verify() {
    docker exec -i -e P="$PASSWORD" -e H="$1" "$COOLIFY_APP_CONTAINER" \
        php -r 'echo password_verify(getenv("P"), getenv("H")) ? "yes" : "no";'
}

if [[ $VERIFY_ONLY -eq 1 ]]; then
    echo; echo "  Checking the supplied password against each account:"
    match=0; nomatch=0
    for e in "${TARGETS[@]}"; do
        h=$(psql_q "SELECT password FROM users WHERE email = '${e//\'/\'\'}';")
        if [[ "$(php_verify "$h")" == "yes" ]]; then
            match=$((match + 1))
        else
            nomatch=$((nomatch + 1)); echo "    differs: $e"
        fi
    done
    echo
    echo "  matches: $match    differs: $nomatch"
    echo
    echo "Verify only — nothing was changed."
    exit 0
fi

# ---- plan ---------------------------------------------------------------
echo
echo "  Will set the SAME password on ${#TARGETS[@]} account(s):"
printf '    %s\n' "${TARGETS[@]}" | head -40
[[ ${#TARGETS[@]} -gt 40 ]] && echo "    ... and $(( ${#TARGETS[@]} - 40 )) more"
echo
echo "  This overwrites any password a student set for themselves."
echo "  It does NOT affect GitHub OAuth login, only the destructive-action modals."

if [[ $APPLY -eq 0 ]]; then
    echo
    echo "Dry run — nothing changed. Re-run with --apply."
    [[ $GENERATE -eq 1 ]] && echo "(--generate produced a password but did not use it; re-run with --apply.)"
    exit 0
fi

# ---- apply --------------------------------------------------------------
HASH=$(docker exec -i -e P="$PASSWORD" "$COOLIFY_APP_CONTAINER" \
         php -r 'echo password_hash(getenv("P"), PASSWORD_BCRYPT);')
if [[ -z "$HASH" || "$HASH" != \$2y\$* ]]; then
    echo "ERROR: could not compute a bcrypt hash via the coolify container." >&2
    exit 3
fi

# One transaction, emails listed explicitly. SQL goes over stdin so the hash
# never lands in a file or in argv.
{
    echo "BEGIN;"
    for e in "${TARGETS[@]}"; do
        echo "UPDATE users SET password = '${HASH//\'/\'\'}', updated_at = NOW()"
        echo " WHERE email = '${e//\'/\'\'}';"
    done
    echo "COMMIT;"
} | docker exec -i "$COOLIFY_DB_CONTAINER" \
      psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -v ON_ERROR_STOP=1 -q

# ---- verify -------------------------------------------------------------
ok=0; bad=0
for e in "${TARGETS[@]}"; do
    h=$(psql_q "SELECT password FROM users WHERE email = '${e//\'/\'\'}';")
    if [[ "$(php_verify "$h")" == "yes" ]]; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "  FAILED: $e"; fi
done

echo
if [[ $GENERATE -eq 1 ]]; then
    echo "  Generated password (record it now, it is not stored anywhere):"
    echo
    echo "      $PASSWORD"
    echo
fi
common_banner_end
if [[ $bad -eq 0 ]]; then
    echo "SUCCESS: $ok account(s) now use the new password, all verified."
    echo "Tell students out of band (Canvas or in class). Do not commit it."
    exit 0
fi
echo "PARTIAL: $ok verified, $bad failed. Investigate before telling students." >&2
exit 1
