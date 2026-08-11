#!/usr/bin/env bash
# =============================================================================
# smoke-test-cluster.sh — end-to-end smoke test for the classroom cluster
#
# Runs from your Mac (or anywhere on the BYU VPN) and validates:
#   - LiteLLM proxy on ml-capstone.cs.byu.edu:4000        (chat + FIM completions via the pool)
#   - Direct-to-vLLM on castor + pollux  (bypasses LiteLLM; catches upstream issues)
#   - Coolify UI reachability on ml-capstone-admin.cs.byu.edu
#   - Sentiment app (defaults to the classroom Coolify; override with a flag)
#
# The LLM checks show the prompt sent and the actual model output so you can
# eyeball response quality, not just pass/fail. Every check runs even if
# earlier ones fail. Pass/fail summary at the end; exit code non-zero on failure.
#
# Requires: bash, curl, python3.  Optional: nothing else.
#
# Usage:
#   ./smoke-test-cluster.sh                   # sentiment app on the classroom Coolify (needs DNS)
#   ./smoke-test-cluster.sh --local           # sentiment app on localhost:8000
#   ./smoke-test-cluster.sh -p 8100           # sentiment app at http://ml-capstone.cs.byu.edu:8100
#   ./smoke-test-cluster.sh -s <URL>          # sentiment app at custom URL
#   ./smoke-test-cluster.sh --no-sentiment    # skip sentiment section entirely
#
# The -p / --rigel-port shortcut is for the "direct port" Coolify deploy path
# (no DNS wiring needed): publish the container's port to a host port on the
# ml-capstone box, then hit it directly.
#
# Any config var can also be overridden via env, e.g.
#   PROXY_HOST=rigel.cs.byu.edu ./smoke-test-cluster.sh     # if the ml-capstone DNS is broken and you need to hit the physical host directly
#   SENTIMENT_URL=https://sentiment.ml-capstone.cs.byu.edu ./smoke-test-cluster.sh
# =============================================================================

set -u

# ---- Configuration ------------------------------------------------------
# Default to the abstraction (ml-capstone.cs.byu.edu) rather than the physical
# hostname (rigel.cs.byu.edu). Override via env to hit the physical box directly
# if DNS is broken; both hostnames resolve to the same IP so :4000/:8100 work
# either way (only :443 flows through HAProxy).
: "${PROXY_HOST:=ml-capstone.cs.byu.edu}"
: "${PROXY_PORT:=4000}"
: "${COOLIFY_PORT:=8000}"
: "${GPU_HOST_A:=castor.cs.byu.edu}"
: "${GPU_HOST_B:=pollux.cs.byu.edu}"
: "${CHAT_PORT:=8000}"
: "${FIM_PORT:=8010}"
: "${CHAT_MODEL:=Qwen/Qwen3-Coder-Next-FP8}"
: "${FIM_MODEL:=Qwen/Qwen2.5-Coder-7B}"
: "${API_KEY:=sk-noauth}"
: "${TIMEOUT:=30}"

# Sentiment app: default targets the Coolify deploy on rigel.
# Override via --local, --sentiment/-s <url>, or SENTIMENT_URL env var.
: "${SENTIMENT_URL:=http://sentiment-test-app.ml-capstone.cs.byu.edu}"
SENTIMENT_ENABLED=1

# ---- Argument parsing ---------------------------------------------------
usage() {
    sed -n '2,/^# ===*$/{ /^# ===*$/d; s/^# \{0,1\}//p; }' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local|-l)          SENTIMENT_URL="http://127.0.0.1:8000"; shift ;;
        --sentiment|-s)      SENTIMENT_URL="$2"; shift 2 ;;
        --rigel-port|-p)
            [[ "$2" =~ ^[0-9]+$ ]] || { echo "--rigel-port needs a numeric port, got '$2'" >&2; exit 2; }
            SENTIMENT_URL="http://${PROXY_HOST}:$2"
            shift 2 ;;
        --no-sentiment)      SENTIMENT_ENABLED=0; shift ;;
        -h|--help)           usage ;;
        --)                  shift; break ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 2 ;;
        *)
            # First positional argument = sentiment URL (or 'local' shorthand)
            case "$1" in
                local|localhost)  SENTIMENT_URL="http://127.0.0.1:8000" ;;
                *)                SENTIMENT_URL="$1" ;;
            esac
            shift ;;
    esac
done

# ---- Colors -------------------------------------------------------------
if [[ -t 1 ]]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'
    D=$'\033[90m'; B=$'\033[1m'; Z=$'\033[0m'
else
    G=""; R=""; Y=""; C=""; D=""; B=""; Z=""
fi

PASS=0
FAIL=0
FAILED=()

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

record() {
    local name="$1" status="$2"
    if [[ "$status" == PASS ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); FAILED+=("$name"); fi
}

# ---- One-line pass/fail check ------------------------------------------
# Usage: check "name" cmd args...
check() {
    local name="$1"; shift
    local start end ms out ec
    start=$(now_ms)
    out=$("$@" 2>&1); ec=$?
    end=$(now_ms); ms=$((end - start))
    if (( ec == 0 )); then
        printf "  ${G}PASS${Z}  %-55s ${D}%dms${Z}\n" "$name" "$ms"
        record "$name" PASS
    else
        printf "  ${R}FAIL${Z}  %-55s ${D}%dms${Z}\n" "$name" "$ms"
        printf "%s\n" "$out" | head -3 | sed "s|^|        ${D}| ; s|\$|${Z}|"
        record "$name" FAIL
    fi
}

# ---- Curl helpers -------------------------------------------------------

url_contains() {
    local url="$1" expect="$2" body
    body=$(curl -sSf -m "$TIMEOUT" "$url") || return 1
    grep -qF -- "$expect" <<<"$body"
}

http_ok() {
    local url="$1" code
    code=$(curl -sS -o /dev/null -w '%{http_code}' -m "$TIMEOUT" "$url") || return 1
    [[ $code =~ ^[23] ]]
}

# Given a JSON body, extract a field with python (no jq dependency)
json_get() {
    local field="$1"
    python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in '''$field'''.split('.'):
    if k.isdigit(): d = d[int(k)]
    else:           d = d[k]
print(d)
"
}

wrap_indent() {
    local indent="$1"
    fold -s -w 80 | sed "s|^|${indent}|"
}

# Build a JSON body safely by passing prompt+model via env → python.
# Avoids the nightmare of quoting through nested $(...) and heredocs.
build_chat_json() {
    MODEL="$1" PROMPT="$2" MAXTOK="$3" TEMP="$4" python3 -c '
import json, os
print(json.dumps({
    "model": os.environ["MODEL"],
    "messages": [{"role": "user", "content": os.environ["PROMPT"]}],
    "max_tokens": int(os.environ["MAXTOK"]),
    "temperature": float(os.environ["TEMP"]),
}))
'
}

build_completion_json() {
    MODEL="$1" PROMPT="$2" MAXTOK="$3" TEMP="$4" python3 -c '
import json, os
print(json.dumps({
    "model": os.environ["MODEL"],
    "prompt": os.environ["PROMPT"],
    "max_tokens": int(os.environ["MAXTOK"]),
    "temperature": float(os.environ["TEMP"]),
}))
'
}

# ---- Visible chat completion -------------------------------------------
# Usage: show_chat "check name" BASE_URL MODEL "prompt"
show_chat() {
    local name="$1" base_url="$2" model="$3" prompt="$4"
    printf "\n  ${C}▸ %s${Z}\n" "$name"
    printf "    ${D}model:${Z}  %s\n" "$model"
    printf "    ${D}prompt:${Z}\n"
    printf '%b\n' "$prompt" | wrap_indent "      "

    local body_json start end ms body ec content tokens
    body_json=$(build_chat_json "$model" "$prompt" 250 0.3)
    start=$(now_ms)
    body=$(curl -sSf -m "$TIMEOUT" "$base_url/chat/completions" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $API_KEY" \
        -d "$body_json" 2>&1); ec=$?
    end=$(now_ms); ms=$((end - start))

    if (( ec != 0 )); then
        printf "    ${R}FAIL${Z}  %dms\n" "$ms"
        printf "%s\n" "$body" | head -3 | sed "s|^|      ${D}| ; s|\$|${Z}|"
        record "$name" FAIL
        return
    fi

    content=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d["choices"][0]["message"]["content"])
except Exception as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr); sys.exit(1)
' <<<"$body" 2>&1) || {
        printf "    ${R}FAIL${Z}  %dms — bad JSON body\n" "$ms"
        printf "%s\n" "$body" | head -3 | sed "s|^|      ${D}| ; s|\$|${Z}|"
        record "$name" FAIL
        return
    }

    tokens=$(python3 -c '
import json, sys
try:    print(json.loads(sys.stdin.read())["usage"]["completion_tokens"])
except: print("?")
' <<<"$body")

    printf "    ${D}response (%dms, %s tokens):${Z}\n" "$ms" "$tokens"
    printf "%s\n" "$content" | wrap_indent "      "
    printf "    ${G}PASS${Z}\n"
    record "$name" PASS
}

# ---- Visible FIM completion --------------------------------------------
# Usage: show_fim "check name" BASE_URL MODEL "prompt"
show_fim() {
    local name="$1" base_url="$2" model="$3" prompt="$4"
    printf "\n  ${C}▸ %s${Z}\n" "$name"
    printf "    ${D}model:${Z}  %s\n" "$model"
    printf "    ${D}prompt (with newlines interpreted):${Z}\n"
    printf '%b\n' "$prompt" | sed "s|^|      |"

    local body_json start end ms body ec text
    body_json=$(build_completion_json "$model" "$(printf '%b' "$prompt")" 100 0.1)
    start=$(now_ms)
    body=$(curl -sSf -m "$TIMEOUT" "$base_url/completions" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $API_KEY" \
        -d "$body_json" 2>&1); ec=$?
    end=$(now_ms); ms=$((end - start))

    if (( ec != 0 )); then
        printf "    ${R}FAIL${Z}  %dms\n" "$ms"
        printf "%s\n" "$body" | head -3 | sed "s|^|      ${D}| ; s|\$|${Z}|"
        record "$name" FAIL
        return
    fi

    text=$(python3 -c '
import json, sys
try: print(json.loads(sys.stdin.read())["choices"][0]["text"])
except Exception as e: print(f"PARSE_ERROR: {e}", file=sys.stderr); sys.exit(1)
' <<<"$body" 2>&1) || {
        printf "    ${R}FAIL${Z}  %dms — bad JSON body\n" "$ms"
        record "$name" FAIL
        return
    }

    printf "    ${D}completion (%dms):${Z}\n" "$ms"
    printf "%s\n" "$text" | sed "s|^|      |"
    printf "    ${G}PASS${Z}\n"
    record "$name" PASS
}

# ---- Sentiment app demo ------------------------------------------------
show_sentiment() {
    local name="$1" url="$2" text="$3"
    printf "\n  ${C}▸ %s${Z}\n" "$name"
    printf "    ${D}text:${Z}  %s\n" "$text"

    local body_json start end ms body ec
    body_json=$(TEXT="$text" python3 -c '
import json, os
print(json.dumps({"text": os.environ["TEXT"]}))
')
    start=$(now_ms)
    body=$(curl -sSf -m "$TIMEOUT" "$url/analyze" \
        -H 'Content-Type: application/json' \
        -d "$body_json" 2>&1); ec=$?
    end=$(now_ms); ms=$((end - start))

    if (( ec != 0 )); then
        printf "    ${R}FAIL${Z}  %dms\n" "$ms"
        printf "%s\n" "$body" | head -3 | sed "s|^|      ${D}| ; s|\$|${Z}|"
        record "$name" FAIL
        return
    fi

    # v0.4.0 dual-model response: { llm: {...}, local: {...}, agreement: bool }
    local llm_sent llm_conf llm_reason local_sent local_conf local_dev agreement
    llm_sent=$(json_get   llm.sentiment    <<<"$body" 2>/dev/null || echo "?")
    llm_conf=$(json_get   llm.confidence   <<<"$body" 2>/dev/null || echo "?")
    llm_reason=$(json_get llm.reasoning    <<<"$body" 2>/dev/null || echo "?")
    local_sent=$(json_get local.sentiment  <<<"$body" 2>/dev/null || echo "?")
    local_conf=$(json_get local.confidence <<<"$body" 2>/dev/null || echo "?")
    local_dev=$(json_get  local.device     <<<"$body" 2>/dev/null || echo "?")
    agreement=$(json_get  agreement        <<<"$body" 2>/dev/null || echo "?")

    printf "    ${D}response (%dms):${Z}\n" "$ms"
    printf "      llm:    ${B}%-9s${Z}  confidence: %s  ${D}(reasoning: %s)${Z}\n" \
        "$llm_sent" "$llm_conf" "$llm_reason"
    printf "      local:  ${B}%-9s${Z}  confidence: %s  ${D}(device: %s)${Z}\n" \
        "$local_sent" "$local_conf" "$local_dev"
    printf "      agreement: %s\n" "$agreement"

    if [[ "$llm_sent" =~ ^(positive|negative|neutral)$ ]] && \
       [[ "$local_sent" =~ ^(positive|negative|neutral)$ ]]; then
        printf "    ${G}PASS${Z}\n"
        record "$name" PASS
    else
        printf "    ${R}FAIL${Z}  sentiment field missing or invalid in one or both models\n"
        record "$name" FAIL
    fi
}

# ==========================================================================
# Run checks
# ==========================================================================

hr() { printf "%s%s%s\n" "$D" "$(printf '─%.0s' {1..76})" "$Z"; }

printf "\n%sClassroom cluster smoke test%s   proxy=%s  gpu=%s,%s\n" "$B$Y" "$Z" "$PROXY_HOST" "$GPU_HOST_A" "$GPU_HOST_B"
hr

# ---- LiteLLM reachability + demos --------------------------------------
printf "\n${B}LiteLLM proxy (${PROXY_HOST}:${PROXY_PORT})${Z}\n"
check "LiteLLM /v1/models lists classroom-chat"          url_contains "http://$PROXY_HOST:$PROXY_PORT/v1/models" "classroom-chat"
check "LiteLLM /v1/models lists classroom-autocomplete"  url_contains "http://$PROXY_HOST:$PROXY_PORT/v1/models" "classroom-autocomplete"

show_chat \
    "classroom-chat coding prompt" \
    "http://$PROXY_HOST:$PROXY_PORT/v1" \
    "classroom-chat" \
    "Write a Python function that computes the nth Fibonacci number recursively with memoization. Include a docstring and one usage example."

show_fim \
    "classroom-autocomplete FIM" \
    "http://$PROXY_HOST:$PROXY_PORT/v1" \
    "classroom-autocomplete" \
    "def is_prime(n: int) -> bool:\n    \"\"\"Return True if n is prime.\"\"\"\n    "

# ---- Direct vLLM engines (concise pass/fail) ---------------------------
for HOST in "$GPU_HOST_A" "$GPU_HOST_B"; do
    printf "\n${B}Direct vLLM (${HOST})${Z}\n"
    check "${HOST}:${CHAT_PORT} /v1/models serves ${CHAT_MODEL##*/}" url_contains "http://$HOST:$CHAT_PORT/v1/models" "$CHAT_MODEL"
    check "${HOST}:${FIM_PORT}  /v1/models serves ${FIM_MODEL##*/}"  url_contains "http://$HOST:$FIM_PORT/v1/models"  "$FIM_MODEL"
done

# ---- Coolify UI ---------------------------------------------------------
printf "\n${B}Coolify UI (${PROXY_HOST}:${COOLIFY_PORT})${Z}\n"
check "Coolify UI HTTP 2xx/3xx"    http_ok      "http://$PROXY_HOST:$COOLIFY_PORT"
check "Coolify /api/health"        url_contains "http://$PROXY_HOST:$COOLIFY_PORT/api/health" "OK"

# ---- Sentiment app (deployed via Coolify — override with flags) --------
if (( SENTIMENT_ENABLED )); then
    URL="${SENTIMENT_URL%/}"
    printf "\n${B}Sentiment app (${URL})${Z}\n"
    check "sentiment /health"    url_contains "$URL/health" "\"ok\""
    show_sentiment  "positive sample"  "$URL" "I loved the movie, it was fantastic!"
    show_sentiment  "negative sample"  "$URL" "The service was slow and the food was cold."
    show_sentiment  "neutral sample"   "$URL" "The package arrived Tuesday afternoon."
else
    printf "\n${B}Sentiment app${Z}  ${D}(skipped via --no-sentiment)${Z}\n"
fi

# ==========================================================================
# Summary
# ==========================================================================
TOTAL=$((PASS + FAIL))
printf "\n"; hr
printf "%d checks  ${G}%d passed${Z}  ${R}%d failed${Z}\n\n" "$TOTAL" "$PASS" "$FAIL"

if (( FAIL > 0 )); then
    printf "${R}Failed:${Z}\n"
    for name in "${FAILED[@]}"; do
        printf "  - %s\n" "$name"
    done
    printf "\n${Y}Common causes:${Z}\n"
    printf "  - Not on BYU VPN\n"
    printf "  - LiteLLM container restarted mid-request  (docker logs litellm on rigel)\n"
    printf "  - vLLM engine hung after model swap        (systemctl status qwen-chat on castor/pollux)\n"
    printf "  - Coolify still initializing               (docker ps on rigel)\n"
    printf "  - Sentiment app returned malformed JSON    (model temperature too high, or upstream error)\n"
    exit 1
fi

printf "${G}All good.${Z}\n"
exit 0
