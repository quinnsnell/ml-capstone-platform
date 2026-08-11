#!/usr/bin/env bash
# =============================================================================
# Qwen3-Coder Classroom Cluster — uninstaller
#
# Reverses everything install-qwen-cluster.sh did on this machine:
#   - stops + disables + removes the three systemd units
#   - deletes /opt/qwen-cluster (venv, config, and — by default — model cache)
#   - removes the `qwen` service user
#   - removes ufw rules for ports 4000, 8000, 8010 (if ufw is active)
#
# Run:
#   sudo ./uninstall-qwen-cluster.sh                 # interactive confirm
#   sudo ./uninstall-qwen-cluster.sh -y              # non-interactive
#   sudo ./uninstall-qwen-cluster.sh --keep-models   # preserve /opt/qwen-cluster/hf-cache
#
# Safe to re-run — every step tolerates missing pieces.
# =============================================================================
set -euo pipefail

# ---- Configuration --------------------------------------------------------
INSTALL_DIR="/opt/qwen-cluster"
SERVICE_USER="qwen"
HF_CACHE="$INSTALL_DIR/hf-cache"
UNITS=(qwen-chat.service qwen-autocomplete.service qwen-litellm.service)
PORTS=(4000 8000 8010)

# ---- Args -----------------------------------------------------------------
ASSUME_YES=0
KEEP_MODELS=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes)      ASSUME_YES=1 ;;
        --keep-models) KEEP_MODELS=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            echo "Usage: sudo $0 [-y] [--keep-models]" >&2
            exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: this script must be run with sudo/root." >&2
    exit 1
fi

# ---- Progress UI (mirrors installer) --------------------------------------
STEPS_TOTAL=6
STEP_CURRENT=0
SCRIPT_START_TS=$(date +%s)
STEP_START_TS=$SCRIPT_START_TS

if [[ -t 1 ]]; then
    C_HEAD=$'\033[1;36m'; C_OK=$'\033[32m'; C_DIM=$'\033[90m'
    C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_RST=$'\033[0m'
else
    C_HEAD=""; C_OK=""; C_DIM=""; C_WARN=""; C_ERR=""; C_RST=""
fi

_bar() {
    local cur=$1 total=$2 width=30
    local filled=$(( cur * width / total ))
    local empty=$(( width - filled ))
    local pct=$(( cur * 100 / total ))
    printf '['
    (( filled > 0 )) && printf '%*s' "$filled" '' | tr ' ' '#'
    (( empty  > 0 )) && printf '%*s' "$empty"  '' | tr ' ' '-'
    printf '] %3d%%' "$pct"
}

_fmt_elapsed() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

step() {
    if (( STEP_CURRENT > 0 )); then
        local d=$(( $(date +%s) - STEP_START_TS ))
        printf '%s    ✓ done in %s%s\n' "$C_OK" "$(_fmt_elapsed "$d")" "$C_RST"
    fi
    STEP_CURRENT=$(( STEP_CURRENT + 1 ))
    STEP_START_TS=$(date +%s)
    local total=$(( STEP_START_TS - SCRIPT_START_TS ))
    printf '\n%s%s  Step %d/%d: %s%s  %s(total: %s)%s\n' \
        "$C_HEAD" "$(_bar $(( STEP_CURRENT - 1 )) $STEPS_TOTAL)" \
        "$STEP_CURRENT" "$STEPS_TOTAL" "$1" "$C_RST" \
        "$C_DIM" "$(_fmt_elapsed "$total")" "$C_RST"
    printf '%s-----------------------------------------------------------------%s\n' \
        "$C_DIM" "$C_RST"
}

finish() {
    if (( STEP_CURRENT > 0 )); then
        local d=$(( $(date +%s) - STEP_START_TS ))
        printf '%s    ✓ done in %s%s\n' "$C_OK" "$(_fmt_elapsed "$d")" "$C_RST"
    fi
    local total=$(( $(date +%s) - SCRIPT_START_TS ))
    printf '\n%s%s  Uninstall complete%s  %s(total: %s)%s\n\n' \
        "$C_OK" "$(_bar $STEPS_TOTAL $STEPS_TOTAL)" "$C_RST" \
        "$C_DIM" "$(_fmt_elapsed "$total")" "$C_RST"
}

_on_err() {
    local exit_code=$?
    local d=$(( $(date +%s) - STEP_START_TS ))
    local total=$(( $(date +%s) - SCRIPT_START_TS ))
    printf '\n%s%s  FAILED during step %d/%d after %s%s  %s(total: %s)%s\n' \
        "$C_ERR" "$(_bar $(( STEP_CURRENT - 1 )) $STEPS_TOTAL)" \
        "$STEP_CURRENT" "$STEPS_TOTAL" "$(_fmt_elapsed "$d")" "$C_RST" \
        "$C_DIM" "$(_fmt_elapsed "$total")" "$C_RST"
    exit "$exit_code"
}

# ---- Confirmation ---------------------------------------------------------
echo "This will remove the Qwen classroom cluster from THIS machine:"
echo "  • stop, disable, and delete systemd units:"
for u in "${UNITS[@]}"; do echo "      - $u"; done
echo "  • remove ufw rules for TCP ports: ${PORTS[*]} (if ufw is active)"
if (( KEEP_MODELS )); then
    echo "  • wipe $INSTALL_DIR EXCEPT the model cache at $HF_CACHE"
else
    echo "  • wipe $INSTALL_DIR (including model cache — will need re-download)"
fi
echo "  • remove service user: $SERVICE_USER"
echo

if (( ASSUME_YES == 0 )); then
    read -rp "Proceed? [y/N] " reply
    if [[ ! "$reply" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Confirmation passed — arm the ERR trap so failures surface cleanly.
trap _on_err ERR

# ---- 1. Stop services ----------------------------------------------------
step "Stopping services"
for u in "${UNITS[@]}"; do
    if [[ -f "/etc/systemd/system/$u" ]]; then
        systemctl stop "$u" 2>/dev/null || true
        echo "    stopped: $u"
    else
        echo "    (not installed: $u)"
    fi
done

# ---- 2. Disable services -------------------------------------------------
step "Disabling services"
for u in "${UNITS[@]}"; do
    if [[ -f "/etc/systemd/system/$u" ]]; then
        systemctl disable "$u" 2>/dev/null || true
        echo "    disabled: $u"
    else
        echo "    (not installed: $u)"
    fi
done

# ---- 3. Remove unit files ------------------------------------------------
step "Removing systemd unit files"
removed_any=0
for u in "${UNITS[@]}"; do
    if [[ -f "/etc/systemd/system/$u" ]]; then
        rm -f "/etc/systemd/system/$u"
        echo "    removed: /etc/systemd/system/$u"
        removed_any=1
    else
        echo "    (not present: /etc/systemd/system/$u)"
    fi
done
if (( removed_any )); then
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
fi

# ---- 4. Remove ufw rules -------------------------------------------------
step "Removing firewall rules"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${PORTS[@]}"; do
        if ufw delete allow "${p}/tcp" >/dev/null 2>&1; then
            echo "    removed rule: allow ${p}/tcp"
        else
            echo "    (no rule to remove: allow ${p}/tcp)"
        fi
    done
else
    echo "    (ufw not active — nothing to remove)"
fi

# ---- 5. Remove install directory -----------------------------------------
step "Removing install directory"
if [[ -d "$INSTALL_DIR" ]]; then
    if (( KEEP_MODELS )); then
        find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name 'hf-cache' -exec rm -rf {} +
        echo "    wiped $INSTALL_DIR contents"
        if [[ -d "$HF_CACHE" ]]; then
            cache_size=$(du -sh "$HF_CACHE" 2>/dev/null | awk '{print $1}')
            echo "    preserved: $HF_CACHE (${cache_size:-size unknown})"
        fi
    else
        rm -rf "$INSTALL_DIR"
        echo "    removed: $INSTALL_DIR"
    fi
else
    echo "    (not present: $INSTALL_DIR)"
fi

# ---- 6. Remove service user ----------------------------------------------
step "Removing service user"
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    if (( KEEP_MODELS )) && [[ -d "$HF_CACHE" ]]; then
        # Keep the user out of the model cache's ownership chain — chown to root
        # so removing the user doesn't orphan the files.
        chown -R root:root "$INSTALL_DIR" 2>/dev/null || true
    fi
    # --remove also deletes the user's home dir (/home/qwen), created by installer
    userdel --remove "$SERVICE_USER" 2>/dev/null \
        || userdel "$SERVICE_USER" 2>/dev/null \
        || true
    echo "    removed user: $SERVICE_USER"
else
    echo "    (not present: $SERVICE_USER)"
fi

finish

if (( KEEP_MODELS )); then
    echo "Model cache preserved at $HF_CACHE."
    echo "Re-running install-qwen-cluster.sh will re-use it (no re-download)."
    echo
fi
