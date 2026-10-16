#!/usr/bin/env bash
#
# install-whisper-service.sh — stand up shared speech-to-text on rigel and
# register it with the classroom LiteLLM proxy as `classroom-transcribe`.
#
# Runs a speaches container (faster-whisper / CTranslate2) on GPU 0, bound to
# the docker bridge address so LiteLLM can reach it but the VPN cannot, then
# adds one model_list entry to /etc/litellm/config.yaml and restarts LiteLLM.
#
# Safe to re-run. Validates the edited YAML *before* restarting LiteLLM and
# restores the backup if it does not parse, so a typo never reaches the
# running service.
#
#   ./install-whisper-service.sh           # full install, prompts before
#                                          # touching LiteLLM
#   ./install-whisper-service.sh --yes     # no prompt
#   ./install-whisper-service.sh --check    # read-only: report state, change
#                                          # nothing
#   ./install-whisper-service.sh --rollback # remove the entry, restart, drop
#                                          # the container
#
set -euo pipefail

MODEL=Systran/faster-whisper-large-v3
ALIAS=classroom-transcribe
IMAGE=ghcr.io/speaches-ai/speaches:latest-cuda
NAME=whisper
VOLUME=whisper-hf-cache
PORT=8020
GPU=0
CONFIG=/etc/litellm/config.yaml

ASSUME_YES=0
MODE=install
for a in "$@"; do
  case "$a" in
    --yes|-y)   ASSUME_YES=1 ;;
    --check)    MODE=check ;;
    --rollback) MODE=rollback ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '   \033[33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[31mFAILED\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

say "Preflight"

docker ps >/dev/null 2>&1 || die "cannot talk to docker as $(whoami)"
ok "docker reachable"

docker ps --filter name=litellm --format '{{.Names}}' | grep -qx litellm \
  || die "the litellm container is not running — nothing to register against"
ok "litellm container is up"

[ -f "$CONFIG" ] || die "$CONFIG not found"
ok "$CONFIG present"

GW=$(ip -4 addr show docker0 2>/dev/null | grep -oP 'inet \K[\d.]+' || true)
[ -n "$GW" ] || die "could not determine the docker0 bridge address"
ok "docker bridge is $GW (whisper will bind ${GW}:${PORT})"

python3 -c 'import yaml' 2>/dev/null || die "python3 pyyaml missing — needed to validate the config"
ok "pyyaml available"

if command -v ffmpeg >/dev/null 2>&1; then
  HAVE_FFMPEG=1; ok "ffmpeg present (end-to-end test will run)"
else
  HAVE_FFMPEG=0; warn "ffmpeg absent — skipping the end-to-end audio test"
fi

nvidia-smi --query-gpu=index,memory.used --format=csv,noheader 2>/dev/null \
  | sed 's/^/   gpu /' || warn "nvidia-smi unavailable"

# ----------------------------------------------------------------- rollback

if [ "$MODE" = rollback ]; then
  say "Rollback"
  sudo python3 - "$CONFIG" "$ALIAS" <<'PY'
import re, sys, pathlib
path, alias = sys.argv[1], sys.argv[2]
p = pathlib.Path(path); s = p.read_text()
pat = re.compile(r'\n?^  - model_name: ' + re.escape(alias) + r'\n(?:^(?:    |\n).*\n)*', re.M)
new, n = pat.subn('\n', s)
if not n:
    print('   entry not present'); raise SystemExit(0)
p.write_text(new); print(f'   removed {n} entry')
PY
  sudo python3 -c "
import yaml,sys
d=yaml.safe_load(open('$CONFIG'))
names=[m['model_name'] for m in d['model_list']]
assert '$ALIAS' not in names, names
print('   config now lists:', names)
" || die "config did not parse after removal — restore a .bak- file by hand"
  sudo docker restart litellm >/dev/null && ok "litellm restarted"
  docker rm -f "$NAME" >/dev/null 2>&1 && ok "container $NAME removed" || true
  echo
  echo "Model cache volume '$VOLUME' was left in place (delete with:"
  echo "  docker volume rm $VOLUME )"
  exit 0
fi

# -------------------------------------------------------------------- check

report_state() {
  say "Current state"
  if docker ps --filter name="^${NAME}$" --format '{{.Status}} {{.Ports}}' | grep -q .; then
    ok "container: $(docker ps --filter name=^${NAME}$ --format '{{.Status}}  {{.Ports}}')"
    curl -s -m 8 -o /dev/null -w "   health: HTTP %{http_code}\n" "http://${GW}:${PORT}/health" || true
    echo -n "   models downloaded: "
    curl -s -m 8 "http://${GW}:${PORT}/v1/models" \
      | python3 -c 'import sys,json;print([m["id"] for m in json.load(sys.stdin)["data"]] or "none")' 2>/dev/null \
      || echo "unreachable"
  else
    warn "container $NAME is not running"
  fi
  echo -n "   litellm model_list: "
  curl -s -m 8 http://localhost:4000/v1/models \
    | python3 -c 'import sys,json;print([m["id"] for m in json.load(sys.stdin)["data"]])' 2>/dev/null \
    || echo "unreachable"
  echo -n "   litellm -> whisper: "
  docker exec litellm python3 -c "
import socket
s=socket.socket(); s.settimeout(5)
try: s.connect(('${GW}',${PORT})); print('reachable')
except Exception as e: print('NOT reachable —',e)
finally: s.close()
" 2>/dev/null || echo "could not test"
}

if [ "$MODE" = check ]; then
  report_state
  echo
  echo "Read-only. Nothing changed."
  exit 0
fi

# ------------------------------------------------------- 1. whisper container

say "1. Whisper container on GPU ${GPU}, bound to ${GW}:${PORT}"

docker volume create "$VOLUME" >/dev/null
ok "volume $VOLUME ready (model cache survives recreation)"

if docker ps -a --filter name="^${NAME}$" --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null
  ok "removed previous container"
fi

docker run -d --name "$NAME" --restart=always \
  --gpus "\"device=${GPU}\"" \
  -p "${GW}:${PORT}:8000" \
  -v "${VOLUME}:/home/ubuntu/.cache/huggingface" \
  "$IMAGE" >/dev/null
ok "started $NAME"

printf '   waiting for health'
for i in $(seq 1 40); do
  if [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://${GW}:${PORT}/health" || true)" = 200 ]; then
    printf ' — up\n'; break
  fi
  printf '.'; sleep 2
  [ "$i" = 40 ] && { printf '\n'; docker logs --tail 25 "$NAME"; die "whisper never became healthy"; }
done

# ----------------------------------------------------------- 2. model weights

say "2. Model weights: $MODEL"

if curl -s -m 10 "http://${GW}:${PORT}/v1/models" \
     | python3 -c "import sys,json;sys.exit(0 if '$MODEL' in [m['id'] for m in json.load(sys.stdin)['data']] else 1)"; then
  ok "already downloaded"
else
  echo "   downloading (~3 GB, about a minute on a warm cache)..."
  curl -s -m 1800 -f -X POST "http://${GW}:${PORT}/v1/models/${MODEL}" >/dev/null \
    || die "model download failed"
  ok "downloaded"
fi

# ------------------------------------------------- 3. reachability from proxy

say "3. Reachability from inside the litellm container"

docker exec litellm python3 -c "
import socket, sys
s=socket.socket(); s.settimeout(5)
try:
    s.connect(('${GW}',${PORT})); print('   ok  litellm can reach ${GW}:${PORT}')
except Exception as e:
    print('   NOT reachable:', e); sys.exit(1)
finally: s.close()
" || die "litellm cannot reach whisper — the config entry would not work"

# ----------------------------------------------------------- 4. config entry

say "4. Register '$ALIAS' in $CONFIG"

BACKUP="${CONFIG}.bak-$(date +%Y%m%d-%H%M%S)"
sudo cp "$CONFIG" "$BACKUP"
ok "backed up to $BACKUP"

sudo python3 - "$CONFIG" "$ALIAS" "$MODEL" "$GW" "$PORT" <<'PY'
import re, sys, pathlib
path, alias, model, gw, port = sys.argv[1:6]
p = pathlib.Path(path); s = p.read_text()

if alias in s:
    print('   entry already present — leaving it alone'); raise SystemExit(0)

entry = (f"  - model_name: {alias}\n"
         f"    litellm_params:\n"
         f"      model: openai/{model}\n"
         f"      api_base: http://{gw}:{port}/v1\n"
         f"      api_key: sk-noauth\n"
         f"    model_info:\n"
         f"      mode: audio_transcription\n")

m = list(re.finditer(r'^litellm_settings:', s, re.M))
if len(m) == 1:
    p.write_text(s[:m[0].start()] + entry + '\n' + s[m[0].start():])
elif re.search(r'^model_list:', s, re.M):
    p.write_text(s.rstrip('\n') + '\n' + entry)        # model_list is last
else:
    sys.exit('   could not locate model_list: — insert the entry by hand')
print('   inserted')
PY

say "5. Validate the edited YAML (before restarting anything)"

if ! sudo python3 -c "
import yaml, sys
d = yaml.safe_load(open('$CONFIG'))
names = [m['model_name'] for m in d['model_list']]
assert '$ALIAS' in names, f'alias missing from model_list: {names}'
e = next(m for m in d['model_list'] if m['model_name'] == '$ALIAS')
assert e['model_info']['mode'] == 'audio_transcription', e
print('   model_list:', names)
"; then
  sudo cp "$BACKUP" "$CONFIG"
  die "edited config is invalid — restored $BACKUP, litellm was NOT restarted"
fi
ok "config parses and the entry looks right"

# -------------------------------------------------------- 6. restart litellm

say "6. Restart litellm"

if [ "$ASSUME_YES" != 1 ]; then
  echo "   This briefly interrupts classroom-chat for everyone."
  read -r -p "   Restart litellm now? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo
       echo "   Stopped before the restart. The config entry is in place."
       echo "   Finish with:  sudo docker restart litellm"
       echo "   Undo with:    sudo cp $BACKUP $CONFIG"
       exit 0 ;;
  esac
fi

sudo docker restart litellm >/dev/null
printf '   waiting for litellm'
for i in $(seq 1 30); do
  if [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://localhost:4000/health/readiness || true)" = 200 ]; then
    printf ' — up\n'; break
  fi
  printf '.'; sleep 2
  [ "$i" = 30 ] && { printf '\n'; die "litellm did not come back — restore with: sudo cp $BACKUP $CONFIG && sudo docker restart litellm"; }
done

# ------------------------------------------------------------- 7. verify

say "7. Verify through the proxy"

curl -s -m 10 http://localhost:4000/v1/models \
  | python3 -c "
import sys, json
ids = [m['id'] for m in json.load(sys.stdin)['data']]
print('   /v1/models:', ids)
assert '$ALIAS' in ids, 'alias not advertised'
" || die "'$ALIAS' is not listed by litellm"
ok "litellm advertises $ALIAS"

echo -n "   chat models still answering: "
code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST http://localhost:4000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"classroom-chat","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' || true)
[ "$code" = 200 ] && echo "HTTP 200" || warn "HTTP $code — check the GPU hosts, unrelated to this change"

if [ "$HAVE_FFMPEG" = 1 ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  ffmpeg -nostdin -loglevel error -y -f lavfi -i "sine=f=200:d=2" -ar 16000 -ac 1 "$tmp/t.wav"
  echo "   end-to-end transcription through :4000 —"
  body=$(curl -s -m 60 http://localhost:4000/v1/audio/transcriptions \
    -F "model=$ALIAS" -F "file=@$tmp/t.wav" || true)
  echo "     $body"
  echo "$body" | grep -q '"text"' \
    && ok "transcription routed end to end" \
    || die "transcription did not route — check: docker logs litellm --tail 40"
  echo
  echo "   (that clip is a pure tone, so the text itself is invented —"
  echo "    the point is that it routed and returned 200)"
fi

say "Done"
cat <<EOF
   Students call it as:

     base_url  http://ml-capstone.cs.byu.edu:4000/v1
     model     $ALIAS
     api_key   sk-noauth            (CS VPN required)

   Whisper itself listens on ${GW}:${PORT} — the docker bridge only, so it is
   not reachable from the VPN except through litellm.

   Re-check anytime:  $0 --check
   Undo everything:   $0 --rollback
   Config backup:     $BACKUP
EOF
