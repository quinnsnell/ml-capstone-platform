#!/usr/bin/env bash
# =============================================================================
# Qwen3-Coder Classroom Cluster — GPU-host installer & daemonizer
#
# Installs vLLM under /opt/qwen-cluster, downloads the chosen chat +
# autocomplete models, writes two systemd units, and enables them:
#   - qwen-chat.service           (vLLM chat model, largest GPU, port 8000)
#   - qwen-autocomplete.service   (vLLM FIM model,  next GPU,    port 8010)
#
# The front-end LiteLLM proxy lives on rigel.cs.byu.edu (see the admin guide);
# this script installs only the raw vLLM engines the front-end fans out to.
#
# Usage:
#   sudo ./install-qwen-cluster.sh [OPTIONS]
#
# Model selection (defaults to profile "qwen3-coder"):
#   --profile NAME             Use a named preset (--list-profiles to see them)
#   --chat-model REPO          Override the chat model (HF repo id)
#   --fim-model  REPO          Override the FIM/autocomplete model (HF repo id)
#   --chat-extra-args "..."    Extra vLLM CLI flags for the chat engine
#   --fim-extra-args  "..."    Extra vLLM CLI flags for the FIM engine
#   --chat-max-len N           Chat --max-model-len (default from profile)
#   --fim-max-len  N           FIM  --max-model-len (auto-scales to FIM GPU VRAM)
#   --list-profiles            Print available profiles and exit
#   -h, --help                 Print this help and exit
#
# Examples:
#   # Default (Qwen3-Coder-Next-FP8 chat + Qwen2.5-Coder-7B FIM):
#   sudo ./install-qwen-cluster.sh
#
#   # Swap to GLM-4.5-Air for chat, keep Qwen for FIM:
#   sudo ./install-qwen-cluster.sh --profile glm-45-air
#
#   # Custom model not covered by a profile:
#   sudo ./install-qwen-cluster.sh \
#       --chat-model deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct \
#       --chat-extra-args "--trust-remote-code"
#
# Re-running the script is safe (idempotent) — including with a different
# profile, which swaps the running model.
# =============================================================================
set -euo pipefail

# ---- Configuration (paths / ports) ---------------------------------------
INSTALL_DIR="/opt/qwen-cluster"
SERVICE_USER="qwen"
CHAT_PORT=8000
FIM_PORT=8010

# ---- Model profiles ------------------------------------------------------
# To add a new profile, add its name to KNOWN_PROFILES, then add a matching
# branch to _apply_profile() (model + args + max-len) and _profile_desc()
# (short description for --list-profiles output).
KNOWN_PROFILES=(qwen3-coder qwen3-coder-30b glm-45-air)
DEFAULT_PROFILE="qwen3-coder"

_apply_profile() {
    case "$1" in
        qwen3-coder)
            CHAT_MODEL="Qwen/Qwen3-Coder-Next-FP8"
            FIM_MODEL="Qwen/Qwen2.5-Coder-7B"
            CHAT_EXTRA_ARGS=""
            FIM_EXTRA_ARGS=""
            CHAT_MAX_LEN=131072
            ;;
        qwen3-coder-30b)
            CHAT_MODEL="Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"
            FIM_MODEL="Qwen/Qwen2.5-Coder-7B"
            CHAT_EXTRA_ARGS=""
            FIM_EXTRA_ARGS=""
            CHAT_MAX_LEN=131072
            ;;
        glm-45-air)
            CHAT_MODEL="zai-org/GLM-4.5-Air-FP8"
            FIM_MODEL="Qwen/Qwen2.5-Coder-7B"
            CHAT_EXTRA_ARGS="--trust-remote-code --tool-call-parser glm45 --reasoning-parser glm45 --enable-auto-tool-choice"
            FIM_EXTRA_ARGS=""
            CHAT_MAX_LEN=131072
            ;;
        *)
            echo "ERROR: unknown profile: $1" >&2
            echo "Available: ${KNOWN_PROFILES[*]}" >&2
            exit 1
            ;;
    esac
}

_profile_desc() {
    case "$1" in
        qwen3-coder)     echo "Qwen3-Coder-Next-FP8 chat + Qwen2.5-Coder-7B FIM (default)" ;;
        qwen3-coder-30b) echo "Qwen3-Coder-30B-A3B-Instruct-FP8 chat + Qwen2.5-Coder-7B FIM" ;;
        glm-45-air)      echo "GLM-4.5-Air-FP8 chat + Qwen2.5-Coder-7B FIM" ;;
        *)               echo "(no description)" ;;
    esac
}

# ---- Help / list-profiles -----------------------------------------------
print_help() { sed -n '2,/^# ===*$/ { /^# ===*$/d; s/^# \{0,1\}//p; }' "$0"; }

list_profiles() {
    echo "Available profiles:"
    local p
    for p in "${KNOWN_PROFILES[@]}"; do
        printf "  %-18s  %s\n" "$p" "$(_profile_desc "$p")"
    done
    echo
    echo "Default: $DEFAULT_PROFILE"
}

# ---- Argument parsing ---------------------------------------------------
PROFILE=""
CHAT_MODEL_OVERRIDE=""
FIM_MODEL_OVERRIDE=""
CHAT_EXTRA_ARGS_OVERRIDE=""
FIM_EXTRA_ARGS_OVERRIDE=""
CHAT_MAX_LEN_OVERRIDE=""
FIM_MAX_LEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)          PROFILE="$2";                    shift 2 ;;
        --chat-model)       CHAT_MODEL_OVERRIDE="$2";        shift 2 ;;
        --fim-model)        FIM_MODEL_OVERRIDE="$2";         shift 2 ;;
        --chat-extra-args)  CHAT_EXTRA_ARGS_OVERRIDE="$2";   shift 2 ;;
        --fim-extra-args)   FIM_EXTRA_ARGS_OVERRIDE="$2";    shift 2 ;;
        --chat-max-len)     CHAT_MAX_LEN_OVERRIDE="$2";      shift 2 ;;
        --fim-max-len)      FIM_MAX_LEN="$2";                shift 2 ;;
        --list-profiles)    list_profiles; exit 0 ;;
        -h|--help)          print_help;    exit 0 ;;
        *)
            echo "ERROR: unexpected argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

# Resolve profile → model settings, then apply per-flag overrides.
PROFILE="${PROFILE:-$DEFAULT_PROFILE}"
_apply_profile "$PROFILE"

[[ -n "$CHAT_MODEL_OVERRIDE"      ]] && CHAT_MODEL="$CHAT_MODEL_OVERRIDE"
[[ -n "$FIM_MODEL_OVERRIDE"       ]] && FIM_MODEL="$FIM_MODEL_OVERRIDE"
[[ -n "$CHAT_EXTRA_ARGS_OVERRIDE" ]] && CHAT_EXTRA_ARGS="$CHAT_EXTRA_ARGS_OVERRIDE"
[[ -n "$FIM_EXTRA_ARGS_OVERRIDE"  ]] && FIM_EXTRA_ARGS="$FIM_EXTRA_ARGS_OVERRIDE"
[[ -n "$CHAT_MAX_LEN_OVERRIDE"    ]] && CHAT_MAX_LEN="$CHAT_MAX_LEN_OVERRIDE"

# ---- Progress UI ---------------------------------------------------------
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
    printf '\n%s%s  All steps complete%s  %s(total: %s)%s\n\n' \
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

# ---- Preflight checks ----------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: this script must be run with sudo/root." >&2
    exit 1
fi
if ! command -v nvidia-smi >/dev/null; then
    echo "ERROR: nvidia-smi not found. Install the NVIDIA driver first." >&2
    exit 1
fi
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
if [[ $GPU_COUNT -lt 2 ]]; then
    echo "ERROR: need at least 2 GPUs; found $GPU_COUNT." >&2
    exit 1
fi
# vLLM's vendored DeepGEMM (used by FP8 chat models like Qwen3-Coder-Next-FP8)
# scans /usr/local/cuda* at import time to locate CUDA. If absent, the engine
# starts fine but crashes at first inference with "DeepGEMM backend is
# unavailable". Fail fast here with the actual install command.
if ! ls -d /usr/local/cuda* >/dev/null 2>&1; then
    cat >&2 <<'CUDAERR'
ERROR: No /usr/local/cuda* directory found.
       vLLM's vendored DeepGEMM (used by FP8 chat models like
       Qwen3-Coder-Next-FP8) reads /usr/local/cuda at import time.
       Without a CUDA toolkit install there, the chat engine will
       import DeepGEMM as a stub and crash at first inference.

       Install CUDA 13.0 (matches torch's built-against version):
         cd /tmp
         wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
         sudo dpkg -i cuda-keyring_1.1-1_all.deb
         sudo apt update
         sudo apt install -y cuda-toolkit-13-0

       Then re-run this installer.
CUDAERR
    exit 1
fi

# Pick the two largest GPUs by VRAM and pin each engine to one by UUID.
# Handles heterogeneous hosts (e.g. Blackwell + RTX 4090) — chat lands on the
# biggest card, FIM on the second — and stays stable across kernel updates
# that could reorder CUDA's default index enumeration. Compute-cap is captured
# so TORCH_CUDA_ARCH_LIST can be set per-engine to the actual card's cap; that
# avoids FlashInfer's JIT arch check tripping over PyTorch's built-in arch
# list (which includes sm_50 and fails the "sm75 or higher" gate).
readarray -t _SORTED_GPUS < <(
    nvidia-smi --query-gpu=uuid,memory.total,name,compute_cap --format=csv,noheader,nounits |
    awk -F', ' '{printf "%d\t%s\t%s\t%s\n", $2, $1, $3, $4}' |
    sort -k1 -n -r
)
CHAT_GPU_VRAM=$(printf '%s' "${_SORTED_GPUS[0]}" | cut -f1)
CHAT_GPU_UUID=$(printf '%s' "${_SORTED_GPUS[0]}" | cut -f2)
CHAT_GPU_NAME=$(printf '%s' "${_SORTED_GPUS[0]}" | cut -f3)
CHAT_GPU_CAP=$( printf '%s' "${_SORTED_GPUS[0]}" | cut -f4)
FIM_GPU_VRAM=$( printf '%s' "${_SORTED_GPUS[1]}" | cut -f1)
FIM_GPU_UUID=$( printf '%s' "${_SORTED_GPUS[1]}" | cut -f2)
FIM_GPU_NAME=$( printf '%s' "${_SORTED_GPUS[1]}" | cut -f3)
FIM_GPU_CAP=$(  printf '%s' "${_SORTED_GPUS[1]}" | cut -f4)

# Scale FIM max-len to the FIM card's VRAM if the user didn't set it, so a
# small card (24 GB 4090) doesn't OOM at KV-cache-hungry defaults.
if [[ -z "$FIM_MAX_LEN" ]]; then
    if   (( FIM_GPU_VRAM < 30000 )); then FIM_MAX_LEN=8192
    elif (( FIM_GPU_VRAM < 50000 )); then FIM_MAX_LEN=16384
    else                                  FIM_MAX_LEN=32768
    fi
fi

cat <<SUMMARY
[ok] Detected $GPU_COUNT GPU(s)
     profile        : $PROFILE
     chat model     : $CHAT_MODEL
     chat max-len   : $CHAT_MAX_LEN
     chat extra args: ${CHAT_EXTRA_ARGS:-<none>}
     chat GPU       : $CHAT_GPU_NAME (${CHAT_GPU_VRAM} MiB, sm_${CHAT_GPU_CAP//./})
                      $CHAT_GPU_UUID
     fim  model     : $FIM_MODEL
     fim  max-len   : $FIM_MAX_LEN
     fim  extra args: ${FIM_EXTRA_ARGS:-<none>}
     fim  GPU       : $FIM_GPU_NAME (${FIM_GPU_VRAM} MiB, sm_${FIM_GPU_CAP//./})
                      $FIM_GPU_UUID
SUMMARY

# Preflight passed — arm the ERR trap so the progress UI shows failures cleanly.
trap _on_err ERR

# ---- 1. OS packages ------------------------------------------------------
step "Installing OS packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip git curl

# ---- 2. Service user + install directory --------------------------------
step "Preparing service user and install dir"
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
# Give the service user access to GPU device nodes on distros that gate them.
for grp in video render; do
    getent group "$grp" >/dev/null && usermod -a -G "$grp" "$SERVICE_USER" || true
done
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$INSTALL_DIR" "$INSTALL_DIR/hf-cache"

# ---- 3. Python venv + pip installs --------------------------------------
step "Creating Python venv"
sudo -u "$SERVICE_USER" python3 -m venv "$INSTALL_DIR/venv"

step "Installing vLLM (this takes a few minutes)"
sudo -u "$SERVICE_USER" "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
sudo -u "$SERVICE_USER" "$INSTALL_DIR/venv/bin/pip" install vllm openai huggingface_hub

# ---- 4. Pre-download models ---------------------------------------------
step "Pre-downloading models (slow — chat model is large)"
sudo -u "$SERVICE_USER" env HF_HOME="$INSTALL_DIR/hf-cache" \
    "$INSTALL_DIR/venv/bin/hf" download "$CHAT_MODEL"
sudo -u "$SERVICE_USER" env HF_HOME="$INSTALL_DIR/hf-cache" \
    "$INSTALL_DIR/venv/bin/hf" download "$FIM_MODEL"

# ---- 5. systemd units ---------------------------------------------------
step "Writing systemd units and firewall rules"
cat > /etc/systemd/system/qwen-chat.service <<EOF
[Unit]
Description=Classroom chat vLLM engine (GPU 0)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
Environment=CUDA_VISIBLE_DEVICES=${CHAT_GPU_UUID}
Environment=TORCH_CUDA_ARCH_LIST=${CHAT_GPU_CAP}
Environment=VLLM_USE_FLASHINFER_SAMPLER=0
Environment=HF_HOME=${INSTALL_DIR}/hf-cache
Environment=PATH=${INSTALL_DIR}/venv/bin:/usr/bin:/bin
ExecStart=${INSTALL_DIR}/venv/bin/python -m vllm.entrypoints.openai.api_server \\
    --model ${CHAT_MODEL} \\
    --host 0.0.0.0 \\
    --port ${CHAT_PORT} \\
    --gpu-memory-utilization 0.90 \\
    --max-num-seqs 256 \\
    --max-model-len ${CHAT_MAX_LEN} \\
    --enable-prefix-caching ${CHAT_EXTRA_ARGS}
Restart=on-failure
RestartSec=15
LimitNOFILE=65535
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/qwen-autocomplete.service <<EOF
[Unit]
Description=Classroom autocomplete/FIM vLLM engine (GPU 1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
Environment=CUDA_VISIBLE_DEVICES=${FIM_GPU_UUID}
Environment=TORCH_CUDA_ARCH_LIST=${FIM_GPU_CAP}
Environment=VLLM_USE_FLASHINFER_SAMPLER=0
Environment=HF_HOME=${INSTALL_DIR}/hf-cache
Environment=PATH=${INSTALL_DIR}/venv/bin:/usr/bin:/bin
ExecStart=${INSTALL_DIR}/venv/bin/python -m vllm.entrypoints.openai.api_server \\
    --model ${FIM_MODEL} \\
    --host 0.0.0.0 \\
    --port ${FIM_PORT} \\
    --gpu-memory-utilization 0.90 \\
    --max-model-len ${FIM_MAX_LEN} \\
    --enable-prefix-caching ${FIM_EXTRA_ARGS}
Restart=on-failure
RestartSec=15
LimitNOFILE=65535
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

# ---- Firewall (best effort; only if ufw is active) -----------------------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${CHAT_PORT}" "${FIM_PORT}"; do
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
        echo "    opened firewall port: ${p}/tcp"
    done
else
    echo "    (ufw not active — skipping firewall config)"
fi

# ---- 6. Enable + start --------------------------------------------------
step "Enabling and starting services"
systemctl daemon-reload
systemctl enable  qwen-chat.service qwen-autocomplete.service
systemctl restart qwen-chat.service qwen-autocomplete.service

finish

cat <<EOF

===============================================================
Install complete. Both vLLM engines are enabled and starting.

Currently serving:
    chat (port ${CHAT_PORT})        : ${CHAT_MODEL}
    autocomplete (port ${FIM_PORT}) : ${FIM_MODEL}
    profile                     : ${PROFILE}

The front-end LiteLLM proxy on rigel.cs.byu.edu points at these
engines; it exposes them to students as the stable aliases
'classroom-chat' and 'classroom-autocomplete'.

Models are large; first startup takes several minutes as vLLM
loads weights and compiles CUDA graphs. Watch progress:

    journalctl -u qwen-chat -f
    journalctl -u qwen-autocomplete -f

Once ready, sanity-check locally:

    curl http://127.0.0.1:${CHAT_PORT}/v1/models
    curl http://127.0.0.1:${FIM_PORT}/v1/models

Service management:

    sudo systemctl status  qwen-chat qwen-autocomplete
    sudo systemctl restart qwen-chat qwen-autocomplete
    sudo systemctl stop    qwen-chat qwen-autocomplete

To swap to a different model, re-run this script with a different
--profile (or --chat-model / --fim-model) — it's idempotent.
===============================================================
EOF
