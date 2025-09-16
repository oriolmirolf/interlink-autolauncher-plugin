#!/usr/bin/env bash
set -euo pipefail

PLUGIN_URL="http://127.0.0.1:8000"

# Quick connectivity check to AMD over password SSH
if ! sshpass -p "${IL_SSH_PASS:-$(. /etc/default/autolauncher-plugin; echo $IL_SSH_PASS)}" \
    ssh -o StrictHostKeyChecking=no "$(. /etc/default/autolauncher-plugin; echo $IL_SSH_DEST)" "hostname && squeue --version" ; then
  echo "SSH to AMD failed — check AMD_USER/AMD_HOST/AMD_PASS."
  exit 1
fi

# Build a minimal PodCreateRequest that asks autolauncher to only create files (no sbatch)
UID="$(uuidgen)"
read -r -d '' PAYLOAD <<'JSON'
[
  {
    "pod": {
      "metadata": {
        "name": "autolauncher-nolaunch",
        "namespace": "default",
        "uid": "REPLACE_UID",
        "annotations": {
          "autolauncher.interlink/cluster": "amd",
          "autolauncher.interlink/workdir": "/gpfs/projects/bsc70/hpai/work",
          "autolauncher.interlink/containerdir": "/gpfs/projects/bsc70/hpai/containers/rocm-sandbox",
          "autolauncher.interlink/singularityVersion": "3.6.4",
          "autolauncher.interlink/binary": "python",
          "autolauncher.interlink/command": "src/does_not_matter.py",
          "autolauncher.interlink/args": "",
          "autolauncher.interlink/qos": "debug",
          "autolauncher.interlink/walltime": "00:05:00",
          "autolauncher.interlink/ntasks": "1",
          "autolauncher.interlink/cpusPerTask": "4"
        }
      },
      "spec": {
        "containers": [
          {
            "name": "trainer",
            "image": "ignored",
            "command": ["python","src/ignored.py"],
            "args": []
          }
        ]
      }
    },
    "configmaps": [],
    "secrets": [],
    "projectedvolumesmaps": [],
    "jobscriptURL": "",
    "nolaunch": true
  }
]
JSON

PAYLOAD="${PAYLOAD/REPLACE_UID/$UID}"

echo ">>> /create"
curl -sS -X POST "$PLUGIN_URL/create" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" | jq .

echo ">>> /status"
curl -sS -G "$PLUGIN_URL/status" \
  --data-urlencode "pods=[{\"metadata\":{\"uid\":\"$UID\",\"name\":\"autolauncher-nolaunch\",\"namespace\":\"default\"}}]" \
  | jq .

echo ">>> /getLogs (will likely be empty since no launch)"
curl -sS -G "$PLUGIN_URL/getLogs" \
  --data-urlencode "req={\"pod_uid\":\"$UID\",\"container\":\"trainer\",\"Opts\":{\"Tail\":100}}" \
  || true

echo "Self-test done."
