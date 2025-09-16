#!/usr/bin/env bash
set -euo pipefail

SOCK="$HOME/.interlink/.plugin.sock"
BASE="http://unix"

echo ">>> Sanity: plugin openapi"
curl -sS --unix-socket "$SOCK" "$BASE/openapi.json" | jq '.info.title'

echo ">>> SSH to AMD check"
AMD_PASS="$(sudo bash -lc '. /etc/default/autolauncher-plugin >/dev/null 2>&1; printf %s "$IL_SSH_PASS"' )"
AMD_DEST="$(sudo bash -lc '. /etc/default/autolauncher-plugin >/dev/null 2>&1; printf %s "$IL_SSH_DEST"' )"
sshpass -p "$AMD_PASS" ssh -o StrictHostKeyChecking=no "$AMD_DEST" 'hostname && squeue --version'

UID="$(uuidgen)"
read -r -d '' PAYLOAD <<JSON
[
  {
    "pod": {
      "metadata": {
        "name": "autolauncher-nolaunch",
        "namespace": "default",
        "uid": "$UID",
        "annotations": {
          "autolauncher.interlink/cluster": "amd",
          "autolauncher.interlink/workdir": "/gpfs/projects/bsc70/hpai/work",
          "autolauncher.interlink/containerdir": "/gpfs/projects/bsc70/hpai/containers/rocm-sandbox",
          "autolauncher.interlink/singularityVersion": "3.6.4",
          "autolauncher.interlink/binary": "python",
          "autolauncher.interlink/command": "src/ignored.py",
          "autolauncher.interlink/args": "",
          "autolauncher.interlink/qos": "debug",
          "autolauncher.interlink/walltime": "00:05:00",
          "autolauncher.interlink/ntasks": "1",
          "autolauncher.interlink/cpusPerTask": "2",
          "autolauncher.interlink/nolaunch": "true"
        }
      },
      "spec": {
        "containers": [
          { "name": "trainer", "image": "ignored", "command": ["python","src/ignored.py"], "args": [] }
        ]
      }
    },
    "configmaps": [],
    "secrets": [],
    "projectedvolumesmaps": []
  }
]
JSON

echo ">>> /create (dry-run via annotation)"
curl -sS --unix-socket "$SOCK" -X POST "$BASE/create" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" | jq .

echo ">>> /status (empty → health)"
curl -sS --unix-socket "$SOCK" -G "$BASE/status" | jq .

echo "Self-test OK."
