#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — shared helpers for the classroom provisioning scripts
#
# Sourced (not executed) by scripts/invite-to-org.sh, provision-gh-teams.sh,
# and provision-teams.sh. Consolidates code that all three needed independent
# copies of: usage extraction, roster picker + CSV header parsing, section
# banners, whitespace trim, gh CLI preflight.
#
# Requires bash 4.3+ (nameref via `local -n`). The provisioning scripts run on
# rigel (Ubuntu bash 5.x) or the admin's Linux laptop — macOS's default bash
# 3.2 will NOT work. If running on macOS, use Homebrew bash: `brew install bash`
# then invoke with `/opt/homebrew/bin/bash ./scripts/foo.sh`.
#
# Every helper is namespaced with a leading "common_" prefix to avoid
# clobbering script-local names. To use:
#
#   LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib"
#   # shellcheck source=lib/common.sh
#   source "$LIB_DIR/common.sh"
# =============================================================================

# ---- Whitespace trim (bash-native — do NOT use xargs, which parses shell
# quoting and blows up on unmatched single quotes like "Quinn's Sandbox").
common_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---- Section banner. Prints matched width, centered-ish title.
# Usage: common_banner "PREFLIGHT"
common_banner() {
    local title="$1"
    local width=67
    local pad_total=$(( width - ${#title} - 2 ))
    local pad_l=$(( pad_total / 2 ))
    local pad_r=$(( pad_total - pad_l ))
    printf '\n%s %s %s\n' \
        "$(printf '=%.0s' $(seq 1 $pad_l))" \
        "$title" \
        "$(printf '=%.0s' $(seq 1 $pad_r))"
}

# End-of-section rule (same width as common_banner).
common_banner_end() {
    printf '%s\n' "$(printf '=%.0s' $(seq 1 67))"
}

# ---- Auto-pick newest roster-*.csv in cwd if $ROSTER not already set.
# Consumed by callers as: ROSTER=$(common_pick_roster "$ROSTER") || exit $?
# Emits to stderr on failure; prints the resolved path to stdout on success.
common_pick_roster() {
    local roster="${1:-}"
    if [[ -n "$roster" ]]; then
        printf '%s' "$roster"
        return 0
    fi
    roster=$(ls -1t roster-*.csv 2>/dev/null | head -n1 || true)
    if [[ -z "$roster" ]]; then
        echo "No --roster given and no roster-*.csv in $(pwd)." >&2
        echo "Create one — see example at roster-example.csv." >&2
        return 2
    fi
    echo "Auto-picked roster: $roster" >&2
    printf '%s' "$roster"
}

# ---- Extract usage doc from the script's header comment block.
# The convention: the header starts with "# =====..." on line 1, followed by
# "# <docstring lines>", terminated by another "# =====..." line. This helper
# prints everything between them with the leading "# " stripped.
# Callers pass "$0" (path to their own script).
common_usage() {
    sed -n '2,/^# ===*$/{ /^# ===*$/d; s/^# \{0,1\}//p; }' "$1"
}

# ---- gh CLI preflight — verify gh is installed, authenticated, and the
# caller has Owner role on the given org. Emits status to stdout, errors to
# stderr; returns non-zero on failure so the caller can exit.
# Usage: common_gh_org_owner_check "byu-ml-capstone"
common_gh_org_owner_check() {
    local org="$1"
    if ! command -v gh >/dev/null 2>&1; then
        echo "  gh CLI not found. Install: https://cli.github.com/" >&2
        return 3
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "  gh not authenticated. Run: gh auth login" >&2
        return 3
    fi
    local caller
    caller=$(gh api /user --jq .login 2>/dev/null || echo "")
    if [[ -z "$caller" ]]; then
        echo "  Could not resolve authenticated user via gh api /user" >&2
        return 3
    fi
    printf '  gh authenticated as: %s\n' "$caller"

    local role
    role=$(gh api "/orgs/$org/memberships/$caller" --jq .role 2>/dev/null || echo "none")
    if [[ "$role" != "admin" ]]; then
        echo "  ERROR: caller '$caller' is not an Owner of '$org' (role=$role)." >&2
        echo "  Owner role required for this operation." >&2
        return 3
    fi
    printf '  Owner role on %s: verified\n' "$org"
    return 0
}

# ---- Parse a CSV header line, populate an associative array with column
# name -> zero-based index. Callers pass the array name to fill and the
# path to the roster file.
#
# Usage:
#     declare -A COL_IDX=()
#     common_csv_parse_header COL_IDX "$ROSTER"
#     for required in team_name email name; do
#         common_csv_require_column COL_IDX "$required" "$HEADER" || exit 2
#     done
common_csv_parse_header() {
    local -n _idx=$1        # nameref to the target associative array
    local roster="$2"
    local header
    header=$(head -n1 "$roster" | tr -d '\r')
    local -a cols=()
    IFS=',' read -r -a cols <<<"$header"
    local i
    for i in "${!cols[@]}"; do
        _idx["${cols[$i]}"]=$i
    done
    # Expose the raw header via a global for error messages
    COMMON_CSV_HEADER="$header"
}

# Assert a required CSV column is present in the parsed header. On miss,
# prints "Roster missing required column '<name>'. Got: <header>" to stderr
# and returns 2.
common_csv_require_column() {
    local -n _idx=$1
    local name="$2"
    if [[ -z "${_idx[$name]+set}" ]]; then
        echo "Roster missing required column '$name'. Got: $COMMON_CSV_HEADER" >&2
        return 2
    fi
    return 0
}

# ---- Convenience: "APPLY" vs "dry-run" label based on an integer flag.
# Usage: mode=$(common_mode_label "$APPLY")
common_mode_label() {
    (( $1 == 1 )) && echo "APPLY" || echo "dry-run (use --apply to execute)"
}
