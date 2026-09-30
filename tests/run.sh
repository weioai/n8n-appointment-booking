#!/usr/bin/env bash
# Runtime test harness for the appointment-booking sample.
#
# Starts a throwaway n8n container, imports the workflow, activates
# them, and POSTs the dry_run fixtures at their webhooks, asserting on the
# returned JSON. No third-party network calls are made: every fixture sets
# "dry_run": true, which keeps every workflow on the branch that skips its
# real HTTP Request / Google Sheets action node.
#
# Usage: tests/run.sh   (run from the repo root or from tests/, either works)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER_NAME="n8n-booking-sample-test"
IMAGE="n8nio/n8n:latest"
PORT=5679

# n8n answers /healthz before its database migrations have finished. Importing at that
# moment makes the CLI run the same migrations at the same time and both fail
# ("database is locked" / "duplicate column name"). Wait until n8n itself says it is
# ready: /healthz/readiness is 200 only once the database is migrated and connected,
# and the log line "Editor is now accessible" marks the end of startup.
wait_ready() {
  local since="$1"
  for i in $(seq 1 180); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/healthz/readiness" || true)
    if [ "$code" = "200" ] && docker logs --since "$since" "$CONTAINER_NAME" 2>&1 | grep -q "Editor is now accessible"; then
      echo "ready after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "n8n never became ready; container logs:"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -100
  return 1
}

cleanup() {
  echo "--- cleaning up: removing $CONTAINER_NAME ---"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- removing any leftover container named $CONTAINER_NAME ---"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "--- starting $CONTAINER_NAME from $IMAGE ---"
docker run -d --name "$CONTAINER_NAME" -p "127.0.0.1:${PORT}:5678" \
  -e N8N_ENCRYPTION_KEY=test-only-key \
  -e N8N_SECURE_COOKIE=false \
  -v "$REPO_DIR/workflows:/import" \
  "$IMAGE" >/dev/null

echo "--- waiting for n8n to finish starting ---"
wait_ready "$STARTED_AT" || exit 1

echo "--- importing workflows ---"
if ! docker exec "$CONTAINER_NAME" n8n import:workflow --separate --input=/import; then
  echo "import:workflow failed"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -100
  exit 1
fi

echo "--- listing imported workflow ids ---"
WF_IDS=$(docker exec "$CONTAINER_NAME" n8n list:workflow --onlyId)
if [ -z "$WF_IDS" ]; then
  echo "no workflows found after import"
  exit 1
fi
echo "$WF_IDS"

# Publishing a workflow's current version marks it active in the database,
# but (per the CLI's own message) it only takes effect for webhook
# registration after n8n restarts. n8n also refuses "import --activeState"
# outside queue/multi-main mode in this version, so publish:workflow per id
# + restart is the working path.
echo "--- publishing (activating) each workflow ---"
while IFS= read -r id; do
  [ -z "$id" ] && continue
  echo "publishing $id"
  if ! docker exec "$CONTAINER_NAME" n8n publish:workflow --id="$id"; then
    echo "publish:workflow failed for $id"
    exit 1
  fi
done <<< "$WF_IDS"

echo "--- restarting container so activation takes effect ---"
RESTARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker restart "$CONTAINER_NAME" >/dev/null

echo "--- waiting for n8n to finish starting again ---"
wait_ready "$RESTARTED_AT" || exit 1

echo "--- confirming workflows are active ---"
docker exec "$CONTAINER_NAME" n8n list:workflow --active=true

# Give the webhook registration a moment after the health endpoint comes up.
sleep 2

echo "--- running assertions against the live webhooks ---"
cd "$REPO_DIR"
if python3 tests/assert_responses.py; then
  echo "--- ALL TESTS PASSED ---"
  exit 0
else
  echo "--- TESTS FAILED ---"
  exit 1
fi
