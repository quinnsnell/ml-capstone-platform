#!/usr/bin/env bash
# =============================================================================
# pin-gpu-host.sh — freeze a GPU host's kernel + NVIDIA driver, and verify the
#                   pin still holds.
#
# castor and pollux run the same OS and the same package set, but they have
# different motherboards and different GPU configurations, so each one needs
# its own NVIDIA driver. Uniformity across hosts is NOT the goal and must not
# be enforced: the goal is that each host stays on the combination that is
# known to work for ITS hardware, and that no unattended update moves it.
#
# The failure this exists to prevent is silent. An update bumps the NVIDIA
# userspace libraries or installs a new kernel; everything keeps running on the
# already-loaded module, so nothing looks wrong. The damage only surfaces at the
# next reboot -- possibly months later, possibly during class -- when the host
# comes up with no usable GPU and both vLLM engines fail to start.
#
# Usage:
#   sudo ./pin-gpu-host.sh                 # check mode (read-only, default)
#   sudo ./pin-gpu-host.sh --freeze        # record current state + apply holds
#   sudo ./pin-gpu-host.sh --show          # print the recorded pin and exit
#   sudo ./pin-gpu-host.sh -h | --help
#
# Check mode exits non-zero if the host has drifted, so it can be run from cron
# or a monitoring hook. Run --freeze once per host, while that host is known
# healthy -- it records what "healthy" currently means on that box.
#
# This script deliberately does NOT install or upgrade anything. Driver
# upgrades on these hosts are a deliberate, scheduled, one-host-at-a-time
# operation; see admin-guide.md "GPU host update policy".
# =============================================================================
set -euo pipefail

PIN_DIR=/etc/qwen-cluster
PIN_FILE="$PIN_DIR/pinned-state.conf"
APT_BLACKLIST=/etc/apt/apt.conf.d/52-no-gpu-autoupgrade

# Kernel metapackages that pull in new kernels. Held so an apt upgrade cannot
# stage a kernel the current driver has never been built against.
KERNEL_HOLDS=(
    linux-generic-hwe-24.04
    linux-headers-generic-hwe-24.04
    linux-image-generic-hwe-24.04
)

MODE=check
while [[ $# -gt 0 ]]; do
    case "$1" in
        --freeze) MODE=freeze; shift ;;
        --show)   MODE=show;   shift ;;
        --check)  MODE=check;  shift ;;
        -h|--help)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

if [[ $EUID -ne 0 && $MODE != show ]]; then
    echo "ERROR: run with sudo/root." >&2
    exit 1
fi

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_RST=""; }

PASS=0; FAIL=0; WARN=0
ok()   { printf '%s[ ok ]%s %s\n'   "$C_OK"   "$C_RST" "$1"; PASS=$((PASS+1)); }
bad()  { printf '%s[fail]%s %s\n'   "$C_BAD"  "$C_RST" "$1"; FAIL=$((FAIL+1)); }
warn() { printf '%s[warn]%s %s\n'   "$C_WARN" "$C_RST" "$1"; WARN=$((WARN+1)); }
note() { printf '%s       %s%s\n'   "$C_DIM"  "$1" "$C_RST"; }

# ---- State probes --------------------------------------------------------
# Each returns a single line, or "unknown" -- never fails the script, so a
# broken host can still be inspected.

probe_kernel() { uname -r; }

probe_driver() {
    # /proc is the loaded module's version -- the ground truth for what the
    # kernel is actually running, unlike nvidia-smi which reports userspace.
    if [[ -r /proc/driver/nvidia/version ]]; then
        awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) {print $i; exit}}' \
            /proc/driver/nvidia/version
    else
        echo unknown
    fi
}

probe_nvidia_smi_version() {
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null |
        head -n1 || echo unknown
}

probe_gpu_models() {
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null |
        sort | uniq -c | sed 's/^ *//' | paste -sd'; ' - || echo unknown
}

# ---- show ----------------------------------------------------------------
if [[ $MODE == show ]]; then
    if [[ -r $PIN_FILE ]]; then
        cat "$PIN_FILE"
    else
        echo "No pin recorded on $(hostname -s). Run: sudo $0 --freeze" >&2
        exit 1
    fi
    exit 0
fi

# ---- freeze --------------------------------------------------------------
if [[ $MODE == freeze ]]; then
    echo "Freezing $(hostname -s) at its current kernel + driver."
    echo

    if ! nvidia-smi >/dev/null 2>&1; then
        echo "ERROR: nvidia-smi is not working on this host right now." >&2
        echo "       Freeze records the CURRENT state as known-good, so only run" >&2
        echo "       it on a host whose GPUs are healthy. Fix the driver first." >&2
        exit 1
    fi

    mkdir -p "$PIN_DIR"
    {
        echo "# Pinned GPU host state for $(hostname -s)."
        echo "# Written by pin-gpu-host.sh --freeze. Each host is pinned to the"
        echo "# combination that works for ITS hardware; castor and pollux are"
        echo "# NOT expected to match each other."
        echo "#"
        echo "# Re-run --freeze only after a deliberate, verified driver or kernel"
        echo "# change on this host."
        echo "PINNED_HOST=$(hostname -s)"
        echo "PINNED_KERNEL=$(probe_kernel)"
        echo "PINNED_DRIVER=$(probe_driver)"
        echo "PINNED_GPUS=\"$(probe_gpu_models)\""
    } > "$PIN_FILE"
    ok "recorded $PIN_FILE"
    sed 's/^/       /' "$PIN_FILE"
    echo

    # Hold the kernel metas plus every installed NVIDIA package, so neither a
    # kernel bump nor a userspace-library bump can land unattended.
    mapfile -t NVIDIA_PKGS < <(
        dpkg-query -W -f '${Package}\n' 2>/dev/null |
        grep -E '^(nvidia-|libnvidia-)' || true
    )
    HOLD_LIST=()
    for p in "${KERNEL_HOLDS[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 && HOLD_LIST+=("$p")
    done
    HOLD_LIST+=("${NVIDIA_PKGS[@]}")

    if ((${#HOLD_LIST[@]})); then
        apt-mark hold "${HOLD_LIST[@]}" >/dev/null
        ok "held ${#HOLD_LIST[@]} packages (kernel metas + NVIDIA)"
    else
        warn "no kernel/NVIDIA packages found to hold"
    fi

    cat > "$APT_BLACKLIST" <<'EOF'
// GPU hosts: kernel and NVIDIA updates are scheduled manually, one host at a
// time, with the other host carrying the class. An unattended bump desyncs the
// driver from the running kernel module and arms an outage that only fires on
// the next reboot.
//
// Managed by scripts/pin-gpu-host.sh. See admin-guide.md "GPU host update
// policy" before changing.
Unattended-Upgrade::Package-Blacklist {
    "linux-";
    "nvidia-";
    "libnvidia-";
};
EOF
    ok "wrote $APT_BLACKLIST"

    echo
    echo "Frozen. Verify any time with: sudo $0"
    exit 0
fi

# ---- check ---------------------------------------------------------------
echo "Checking GPU host pin on $(hostname -s)."
echo

RUNNING_KERNEL=$(probe_kernel)
LOADED_DRIVER=$(probe_driver)

# 1. Driver actually works.
if nvidia-smi >/dev/null 2>&1; then
    ok "nvidia-smi works (driver $(probe_nvidia_smi_version), kernel module $LOADED_DRIVER)"
else
    bad "nvidia-smi FAILED -- GPUs are not usable"
    note "$(nvidia-smi 2>&1 | head -n2)"
    note "A 'Driver/library version mismatch' means the userspace libraries were"
    note "upgraded while an older module is still loaded. Do NOT reboot until"
    note "dkms status shows a module built for the kernel you would boot into."
fi

# 2. Live state still matches what was pinned.
if [[ -r $PIN_FILE ]]; then
    # shellcheck disable=SC1090
    source "$PIN_FILE"
    [[ "${PINNED_KERNEL:-}" == "$RUNNING_KERNEL" ]] \
        && ok "kernel matches pin ($RUNNING_KERNEL)" \
        || bad "kernel DRIFTED: pinned ${PINNED_KERNEL:-?}, running $RUNNING_KERNEL"
    [[ "${PINNED_DRIVER:-}" == "$LOADED_DRIVER" ]] \
        && ok "driver matches pin ($LOADED_DRIVER)" \
        || bad "driver DRIFTED: pinned ${PINNED_DRIVER:-?}, loaded $LOADED_DRIVER"
else
    warn "no pin recorded -- run: sudo $0 --freeze (while this host is healthy)"
fi

# 3. The kernel this host would BOOT INTO has a usable nvidia module.
#    This is the check that catches the reboot bomb while it is still harmless.
#
#    Deliberately narrow. /lib/modules accumulates directories for kernels that
#    were removed long ago; those are clutter, not risk, and flagging them
#    buries the one kernel that actually matters. What matters is the kernel
#    GRUB would pick next -- approximated by the highest-versioned vmlinuz in
#    /boot, which is GRUB's default ordering.
#
#    Uses modinfo rather than `dkms status`, so a driver shipped as a
#    precompiled/signed module counts as present. dkms status only sees
#    DKMS-built modules and would report a false failure on such a host.
has_nvidia_module() { modinfo -k "$1" nvidia >/dev/null 2>&1; }

NEXT_KERNEL=$(ls -1 /boot/vmlinuz-* 2>/dev/null |
    sed 's|.*/vmlinuz-||' | sort -V | tail -n1)

if has_nvidia_module "$RUNNING_KERNEL"; then
    ok "running kernel $RUNNING_KERNEL has an nvidia module"
else
    bad "running kernel $RUNNING_KERNEL has NO nvidia module"
    note "The GPUs are working off an already-loaded module; this host will"
    note "lose them on the next reboot."
fi

if [[ -z "$NEXT_KERNEL" ]]; then
    warn "could not determine the next-boot kernel from /boot"
elif [[ "$NEXT_KERNEL" == "$RUNNING_KERNEL" ]]; then
    ok "next-boot kernel is the running one ($NEXT_KERNEL)"
elif has_nvidia_module "$NEXT_KERNEL"; then
    ok "next-boot kernel $NEXT_KERNEL has an nvidia module"
    note "Newer than the running $RUNNING_KERNEL -- a reboot will switch to it."
else
    bad "next-boot kernel $NEXT_KERNEL has NO nvidia module"
    note "This host is running fine on $RUNNING_KERNEL but would come up on"
    note "$NEXT_KERNEL with no GPU, and both vLLM engines would fail to start."
    note "Before the next reboot, either build the module for it or remove it:"
    note "  sudo apt-get remove --purge linux-image-$NEXT_KERNEL linux-headers-$NEXT_KERNEL"
    note "See troubleshooting.md."
fi

# Stale /lib/modules directories are cosmetic, but a large pile usually means
# old kernels are also still occupying /boot, which eventually breaks upgrades.
STALE=0
while read -r kver; do
    [[ -n "$kver" ]] || continue
    [[ "$kver" == "$RUNNING_KERNEL" || "$kver" == "$NEXT_KERNEL" ]] && continue
    [[ -e "/boot/vmlinuz-$kver" ]] && continue
    STALE=$((STALE+1))
done < <(ls -1 /lib/modules 2>/dev/null)
if (( STALE > 0 )); then
    note "$STALE stale /lib/modules dir(s) for kernels no longer in /boot."
    note "Harmless, but 'sudo apt-get autoremove --purge' tidies them up."
fi

# 4. Holds still in place (an admin may have cleared them and forgotten).
HELD=$(apt-mark showhold 2>/dev/null | grep -cE '^(linux-|nvidia-|libnvidia-)' || true)
(( HELD > 0 )) \
    && ok "$HELD kernel/NVIDIA packages held" \
    || bad "no kernel/NVIDIA holds -- an apt upgrade can move this host"

[[ -r $APT_BLACKLIST ]] \
    && ok "unattended-upgrades blacklist present" \
    || bad "missing $APT_BLACKLIST -- unattended-upgrades can bump kernel/driver"

# 5. dpkg is in a clean state. A half-configured package makes every later
#    apt-get invocation fail, which is what blocked the installer on pollux.
# dpkg Status is three fields: <desired> <error> <status>. Anything settled --
# installed, not-installed, config-files -- is fine regardless of what the
# admin asked for, so a purged package is not a problem. Only an error flag or
# an unsettled status (half-configured, unpacked, half-installed, triggers-*)
# actually blocks later apt-get runs, which is what stalled the installer here.
DPKG_BROKEN=$(dpkg-query -W -f '${Package} ${Status}\n' 2>/dev/null |
    awk '$3 != "ok" || ($4 != "installed" && $4 != "not-installed" && $4 != "config-files")' || true)

if [[ -n "$DPKG_BROKEN" ]]; then
    bad "dpkg has packages in a broken/half-configured state"
    while read -r line; do
        [[ -n "$line" ]] && note "$line"
    done <<< "$DPKG_BROKEN"
    note "Every apt-get install on this host fails until this clears:"
    note "  sudo dpkg --configure -a"
else
    ok "dpkg state is clean"
fi

# 6. Engines up.
for unit in qwen-chat qwen-autocomplete; do
    systemctl is-active --quiet "$unit" \
        && ok "$unit active" \
        || bad "$unit NOT active"
done

echo
printf 'pass=%d  fail=%d  warn=%d\n' "$PASS" "$FAIL" "$WARN"
(( FAIL == 0 )) || exit 1
