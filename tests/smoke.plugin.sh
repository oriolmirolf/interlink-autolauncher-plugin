#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-http}"   # http | unix
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if [[ "$MODE" == "http" ]]; then
  BASE="http://127.0.0.1:8001"
  CURL_GET=(curl -sSf)
  CURL_POST=(curl -sSf -H 'Content-Type: application/json')
elif [[ "$MODE" == "unix" ]]; then
  SOCK="${SOCKET_PATH:-/var/run/interlink/.plugin.sock}"
  [[ -S "$SOCK" ]] || { echo "UNIX socket $SOCK not found"; exit 1; }
  BASE="http://unix"
  CURL_GET=(curl -sSf --unix-socket "$SOCK")
  CURL_POST=(curl -sSf --unix-socket "$SOCK" -H 'Content-Type: application/json')
else
  echo "Usage: $0 {http|unix}"
  exit 1
fi

POD_NAME="smoke"
NS="default"
POD_UID="smoke-uid"
CONTAINER_NAME="c"

echo "==> Health"
"${CURL_GET[@]}" "$BASE/health" && echo

echo "==> Create (busybox sleep)"
cat >"${TMPDIR}/create.json" <<JSON
[
  {
    "pod": {
      "metadata": {
        "name": "$POD_NAME",
        "namespace": "$NS",
        "uid": "$POD_UID",
        "annotations": { "interlink.autolauncher/mode": "local" }
      },
      "spec": {
        "containers": [
          {
            "name": "$CONTAINER_NAME",
            "image": "busybox:1.36",
            "command": ["sh","-c"],
            "args": ["echo start; sleep 3; echo done"]
          }
        ]
      }
    },
    "container": []
  }
]
JSON
"${CURL_POST[@]}" -X POST "$BASE/create" --data-binary @"${TMPDIR}/create.json" | tee "${TMPDIR}/create.out"
echo

sleep 1

echo "==> Status (GET)"
"${CURL_GET[@]}" "${BASE}/status?uid=${POD_UID}" || true
echo

echo "==> Logs (GET, tail=200)"
"${CURL_GET[@]}" "${BASE}/getLogs?uid=${POD_UID}&containerName=${CONTAINER_NAME}&tail=200&timestamps=false&previous=false" || true
echo

echo "==> Delete"
cat >"${TMPDIR}/delete.json" <<JSON
{
  "metadata": {"name":"$POD_NAME","namespace":"$NS","uid":"$POD_UID"},
  "spec": {"containers":[{"name":"$CONTAINER_NAME","image":"busybox:1.36"}]}
}
JSON
"${CURL_POST[@]}" -X POST "$BASE/delete" --data-binary @"${TMPDIR}/delete.json" && echo "OK"
