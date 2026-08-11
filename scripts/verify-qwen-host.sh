#!/usr/bin/env bash
# =============================================================================
# Verify a GPU host is serving chat + FIM via vLLM.
#
# Pure network checks — runs from anywhere with VPN access to the host.
# For each of the chat engine (:8000) and FIM engine (:8010) it:
#   1. hits /v1/models to confirm the engine is up and reports which model
#   2. asks the model to produce Python that defines add(a, b)
#      - chat: /v1/chat/completions with an instruction prompt
#      - FIM : /v1/completions starting from "def add(a, b):\n    return "
#   3. exec's the generated code in a sandboxed python3 subprocess (5s SIGALRM
#      timeout) and asserts add(2, 3) == 5 and add(-1, 4) == 3
#
# Usage:
#   ./verify-qwen-host.sh <hostname>
#
# Examples:
#   ./verify-qwen-host.sh castor.cs.byu.edu
#   ./verify-qwen-host.sh pollux.cs.byu.edu
#
# Exit code: 0 if all checks pass, non-zero otherwise.
# =============================================================================
set -euo pipefail

HOST="${1:-}"
if [[ -z "$HOST" ]]; then
    echo "Usage: $0 <hostname>" >&2
    echo "Example: $0 castor.cs.byu.edu" >&2
    exit 2
fi

CHAT_PORT=8000
FIM_PORT=8010

if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[90m'
    C_HEAD=$'\033[1;36m'; C_RST=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_DIM=""; C_HEAD=""; C_RST=""
fi

FAILURES=0
pass()    { printf '  %s✓%s %s\n' "$C_OK" "$C_RST" "$1"; }
fail()    { printf '  %s✗%s %s\n' "$C_ERR" "$C_RST" "$1"; FAILURES=$((FAILURES+1)); }
info()    { printf '  %s· %s%s\n' "$C_DIM" "$1" "$C_RST"; }
section() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$1" "$C_RST"; }

# Extract a JSON field with python3.
# Usage: json_field <json> <python-expression on d>
json_field() {
    python3 -c 'import sys,json; d=json.load(sys.stdin); print('"$2"')' <<<"$1" 2>/dev/null || true
}

# Sandbox-exec generated code and verify add(a,b) works.
# Reads code from $RAW_CODE env var. Prints "OK" and exits 0 on success,
# prints a short diagnostic and exits non-zero on failure.
verify_add_code() {
    RAW_CODE="$1" python3 <<'PYEOF'
import os, sys, re, signal, tempfile, importlib.util

def die(msg):
    print(msg)
    sys.exit(1)

raw = os.environ["RAW_CODE"]

# Strip markdown fences if the chat model wrapped its code in ```python ... ```.
m = re.search(r"```(?:python|py)?\s*\n?(.*?)```", raw, re.DOTALL)
code = (m.group(1) if m else raw).strip()
if not code:
    die("empty code after extraction")

signal.signal(signal.SIGALRM, lambda *a: die("exec timeout (>5s)"))
signal.alarm(5)

with tempfile.TemporaryDirectory() as td:
    path = os.path.join(td, "gen.py")
    with open(path, "w") as f:
        f.write(code)
    spec = importlib.util.spec_from_file_location("gen", path)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as e:
        die(f"code failed to import: {type(e).__name__}: {e}")
    if not hasattr(mod, "add"):
        names = [n for n in dir(mod) if not n.startswith("_")]
        die(f"no add() function; module defines: {names}")
    try:
        r1 = mod.add(2, 3)
        r2 = mod.add(-1, 4)
    except Exception as e:
        die(f"add() raised: {type(e).__name__}: {e}")
    if r1 != 5 or r2 != 3:
        die(f"wrong results: add(2,3)={r1!r}, add(-1,4)={r2!r}")
    print("OK")
PYEOF
}

# Snippet-format a possibly-multiline string for a single info line.
one_line() { printf '%s' "$1" | tr '\n' '↵' | cut -c1-100; }

check_models() {
    # $1 = port. Sets global MODEL_ID; returns 0/1.
    MODEL_ID=""
    local port="$1"
    local models_json
    if ! models_json=$(curl -sSf --max-time 10 "http://${HOST}:${port}/v1/models" 2>&1); then
        fail "/v1/models failed: $models_json"
        return 1
    fi
    pass "/v1/models responded"
    MODEL_ID=$(json_field "$models_json" 'd["data"][0]["id"]')
    if [[ -z "$MODEL_ID" ]]; then
        fail "could not parse model id from /v1/models response"
        return 1
    fi
    info "serving model: $MODEL_ID"
    return 0
}

check_chat() {
    section "Chat engine (${HOST}:${CHAT_PORT})"
    check_models "$CHAT_PORT" || return

    local body
    body=$(MODEL="$MODEL_ID" python3 -c '
import json, os
print(json.dumps({
    "model": os.environ["MODEL"],
    "messages": [{
        "role": "user",
        "content": (
            "Write a Python function `add(a, b)` that returns their sum. "
            "Respond with only the function definition — no explanation, "
            "no examples, no test code."
        ),
    }],
    "max_tokens": 128,
    "temperature": 0,
}))
')

    local resp
    if ! resp=$(curl -sSf --max-time 60 \
            -H "Content-Type: application/json" -d "$body" \
            "http://${HOST}:${CHAT_PORT}/v1/chat/completions" 2>&1); then
        fail "chat completion request failed: $resp"
        return
    fi
    pass "chat completion returned 200"

    local content
    content=$(json_field "$resp" 'd["choices"][0]["message"]["content"]')
    if [[ -z "$content" ]]; then
        fail "chat response had no content"
        return
    fi
    info "raw: $(one_line "$content")"

    local exec_result
    if exec_result=$(verify_add_code "$content"); then
        pass "generated add(a, b) passes: add(2,3)=5, add(-1,4)=3"
    else
        fail "generated code check failed: $exec_result"
    fi
}

check_fim() {
    section "FIM engine (${HOST}:${FIM_PORT})"
    check_models "$FIM_PORT" || return

    local prompt='def add(a, b):
    """Return the sum of a and b."""
    return '

    local body
    body=$(MODEL="$MODEL_ID" PROMPT="$prompt" python3 -c '
import json, os
print(json.dumps({
    "model": os.environ["MODEL"],
    "prompt": os.environ["PROMPT"],
    "max_tokens": 32,
    "temperature": 0,
    "stop": ["\n\n", "\ndef "],
}))
')

    local resp
    if ! resp=$(curl -sSf --max-time 60 \
            -H "Content-Type: application/json" -d "$body" \
            "http://${HOST}:${FIM_PORT}/v1/completions" 2>&1); then
        fail "completion request failed: $resp"
        return
    fi
    pass "completion request returned 200"

    local completion
    completion=$(json_field "$resp" 'd["choices"][0]["text"]')
    if [[ -z "$completion" ]]; then
        fail "response had no text"
        return
    fi
    info "completion: $(one_line "$completion")"

    local full_code="$prompt$completion"
    local exec_result
    if exec_result=$(verify_add_code "$full_code"); then
        pass "prompt + completion → add(a, b) passes: add(2,3)=5, add(-1,4)=3"
    else
        fail "assembled code check failed: $exec_result"
    fi
}

check_chat
check_fim

echo
if (( FAILURES == 0 )); then
    printf '%sAll checks passed for %s%s\n' "$C_OK" "$HOST" "$C_RST"
    exit 0
else
    printf '%s%d check(s) failed for %s%s\n' "$C_ERR" "$FAILURES" "$HOST" "$C_RST"
    exit 1
fi
