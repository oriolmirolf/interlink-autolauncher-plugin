#!/usr/bin/env bash
set -euo pipefail

# You can run this either on the autolauncher VM (HTTP) or on the worker (UNIX socket).
MODE="${1:-http}"  # http | unix
SOCKET_PATH="${SOCKET_PATH:-/var/run/interlink/.plugin.sock}"
HTTP_BASE="${HTTP_BASE:-http://127.0.0.1:8001}"

echo "==> Health"
if [ "$MODE" = "unix" ]; then
  curl -sSf --unix-socket "${SOCKET_PATH}" http://unix/health && echo
else
  curl -sSf "${HTTP_BASE}/health" && echo
fi

echo "==> Create (busybox sleep)"
cat >/tmp/create.json <<'JSON'
[
  {
    "pod": {
      "metadata": {"name":"smoke","uid":"smoke-uid","namespace":"default"},
      "spec": {
        "containers":[
          {"name":"c","image":"busybox:1.36","command":["sh","-c"],"args":["echo start; sleep 5; echo done"]}
        ]
      }
    },
    "configmaps":[],
    "secrets":[],
    "projectedvolumesmaps":[],
    "container":[]
  }
]
JSON

if [ "$MODE" = "unix" ]; then
  CURL="curl -sSf --unix-socket ${SOCKET_PATH} http://unix"
else
  CURL="curl -sSf ${HTTP_BASE}"
fi

$CURL/create -H 'Content-Type: application/json' --data-binary @/tmp/create.json
echo

sleep 1
echo "==> Status"
$CURL/status -H 'Content-Type: application/json' \
  --data-binary '[{"metadata":{"name":"smoke","uid":"smoke-uid","namespace":"default"},"spec":{"containers":[{"name":"c","image":"busybox:1.36"}]}}]'
echo

echo "==> Logs"
$CURL/getLogs -H 'Content-Type: application/json' \
  --data-binary '{"PodUID":"smoke-uid","Namespace":"default","PodName":"smoke","ContainerName":"c","Opts":{"Tail":1000,"Timestamps":false,"Previous":false}}' \
  || true
echo

echo "==> Delete"
$CURL/delete -H 'Content-Type: application/json' \
  --data-binary '{"metadata":{"name":"smoke","uid":"smoke-uid","namespace":"default"},"spec":{"containers":[{"name":"c","image":"busybox:1.36"}],"initContainers":[]}}'
echo
echo "Smoke test finished."
