#!/usr/bin/env bash
# =============================================================================
# repatch-coolify.sh — reapply the private-github-app team-scoping fix.
#
# Fixes coollabsio/coolify#11449: POST /applications/private-github-app returns
# 404 for is_system_wide GitHub Apps when called with a non-root-team token.
# Upstream PR: https://github.com/coollabsio/coolify/pull/11451
#
# Why this script exists:
#   The full-Terraform bonus lab (testing/qsnell-hello/terraform/) creates
#   coolify_application resources from a student's team-scoped API token,
#   which triggers the bug. Until upstream ships the fix, this instance runs
#   a local patch. Coolify's in-app auto-updater and any manual `docker
#   restart` on a fresh image will wipe the patch; run this script to reapply.
#
# Design:
#   - Dry-run by default; --apply to execute
#   - Idempotent (grep marker before doing anything)
#   - Refuses on Coolify versions outside KNOWN_GOOD_MAJOR_MINORS below
#   - Patches on host (uses patch(1)), fails loudly if upstream file moved
#
# Requires: bash, docker (with access to coolify container), patch(1), curl.
# Run this ON RIGEL as a user in the docker group:
#   - After any Coolify update (auto or manual)
#   - After any coolify container recreate
#
# Usage:
#   ./repatch-coolify.sh              # dry-run: check whether patch is needed
#   ./repatch-coolify.sh --apply      # apply patch + restart if needed
#
# Remove this script once upstream #11451 merges AND rigel is on a Coolify
# version that includes the fix (check the PR's "Milestone" or the release
# notes). Track state in tickets/coolify-upstream/.
# =============================================================================

set -euo pipefail

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

CONTAINER="coolify"
FILE_IN_CONTAINER="/var/www/html/app/Http/Controllers/Api/ApplicationsController.php"
PATCH_MARKER="orWhere('is_system_wide', true)"
DIFF_URL="https://github.com/coollabsio/coolify/pull/11451.diff"

# Coolify major.minor versions this patch has been proven against. If Coolify
# ships a new minor, fetch the current ApplicationsController.php from the
# container, dry-run `patch` against it, and if it applies cleanly, append the
# new minor here.
KNOWN_GOOD_MAJOR_MINORS="4.3 4.4"

APPLY=0
usage() { common_usage "$0"; exit 0; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)   APPLY=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; echo "Run with --help." >&2; exit 2 ;;
    esac
done

# ---- Preflight: Coolify version ----------------------------------------
common_banner "PREFLIGHT"

COOLIFY_IMAGE=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || echo "")
COOLIFY_VERSION="${COOLIFY_IMAGE##*:}"
[[ -z "$COOLIFY_VERSION" ]] && COOLIFY_VERSION="unknown"

version_status="untested"
case "$COOLIFY_VERSION" in
    latest) version_status="floating tag — verify running version elsewhere" ;;
    *) for kg in $KNOWN_GOOD_MAJOR_MINORS; do
           case "$COOLIFY_VERSION" in
               ${kg}.*) version_status="known-good"; break ;;
           esac
       done ;;
esac
printf '  Coolify version:  %s (%s; patch proven against %s)\n' \
    "$COOLIFY_VERSION" "$version_status" "${KNOWN_GOOD_MAJOR_MINORS// /.x, }.x"

if [[ "$version_status" == "untested" ]]; then
    echo "" >&2
    echo "  ERROR: refusing to patch an untested Coolify version." >&2
    echo "  The upstream file (ApplicationsController.php) may have moved." >&2
    echo "  Verify PR #11451 still applies against this version, extend" >&2
    echo "  KNOWN_GOOD_MAJOR_MINORS in this script, and re-run." >&2
    exit 3
fi

# ---- Idempotency check --------------------------------------------------
if docker exec "$CONTAINER" grep -q "$PATCH_MARKER" "$FILE_IN_CONTAINER" 2>/dev/null; then
    printf '  Patch marker "%s" already present.\n' "$PATCH_MARKER"
    common_banner_end
    echo "Nothing to do."
    exit 0
fi

printf '  Patch marker NOT present — patch is needed.\n'
common_banner_end

# ---- Plan ---------------------------------------------------------------
common_banner "PLAN"
cat <<EOF
  1. Fetch upstream PR #11451 diff:
       $DIFF_URL
  2. Extract current $FILE_IN_CONTAINER from container.
  3. Apply diff on the host with patch(1)
       (fails loudly if surrounding context has moved).
  4. Back up in-container file (.bak-<epoch>), copy patched file back in.
  5. Restart '$CONTAINER' (~5-10s downtime).
EOF
common_banner_end

if (( ! APPLY )); then
    echo "Dry-run. Re-run with --apply to execute."
    exit 0
fi

# ---- Apply --------------------------------------------------------------
common_banner "APPLY"
TMPDIR=$(mktemp -d -t coolify-11451.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

echo "  Fetching diff..."
if ! curl -sSL --fail -o "$TMPDIR/fix.diff" "$DIFF_URL"; then
    echo "  ERROR: failed to fetch $DIFF_URL" >&2
    exit 4
fi
[[ -s "$TMPDIR/fix.diff" ]] || { echo "  ERROR: fetched diff is empty" >&2; exit 4; }

echo "  Extracting current file from container..."
docker cp "$CONTAINER:$FILE_IN_CONTAINER" "$TMPDIR/current.php" >/dev/null

echo "  Applying patch on host..."
if ! patch "$TMPDIR/current.php" < "$TMPDIR/fix.diff"; then
    echo "" >&2
    echo "  ERROR: patch failed to apply cleanly." >&2
    echo "  Upstream file has likely moved in this Coolify version." >&2
    echo "  Investigate PR #11451 diff vs the extracted file at:" >&2
    echo "    $TMPDIR/current.php" >&2
    echo "  (tempdir preserved — remove the trap in this script to inspect)" >&2
    exit 5
fi

echo "  Verifying marker in patched file..."
if ! grep -q "$PATCH_MARKER" "$TMPDIR/current.php"; then
    echo "  ERROR: patch reported success but marker not found. Bailing." >&2
    exit 5
fi

echo "  Backing up in-container file..."
BAK="${FILE_IN_CONTAINER}.bak-$(date +%s)"
docker exec "$CONTAINER" cp "$FILE_IN_CONTAINER" "$BAK"
printf '    backup: %s\n' "$BAK"

echo "  Copying patched file into container..."
docker cp "$TMPDIR/current.php" "$CONTAINER:$FILE_IN_CONTAINER" >/dev/null

echo "  Restarting $CONTAINER..."
docker restart "$CONTAINER" >/dev/null
common_banner_end

echo "Patch applied and container restarted."
echo "Verify with: docker exec $CONTAINER grep -n \"$PATCH_MARKER\" $FILE_IN_CONTAINER"
