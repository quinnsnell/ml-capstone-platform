#!/usr/bin/env bash
# Quick local check: build, run, curl a couple endpoints, clean up.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== building ==="
docker build -t hello-world-app:local .

echo
echo "=== running ==="
CID=$(docker run -d --rm -p 8000:8000 hello-world-app:local)
trap 'docker stop "$CID" >/dev/null 2>&1 || true' EXIT

# Wait for /health to come up
for _ in $(seq 1 15); do
    if curl -sSf http://127.0.0.1:8000/health >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

echo
echo "=== GET / ==="
curl -sS http://127.0.0.1:8000/
echo
echo "=== GET /health ==="
curl -sS http://127.0.0.1:8000/health
echo
echo
echo "OK — press Ctrl-C to stop, or wait and the trap will clean up on exit."
