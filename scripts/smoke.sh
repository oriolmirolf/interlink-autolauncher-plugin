#!/usr/bin/env bash
set -euo pipefail
EP="${1:-http://127.0.0.1:8001}"

cat > /tmp/create.json <<'JSON'
[
  {
    "pod": {
      "metadata": {"name":"hello","uid":"uid-long","namespace":"default",
        "annotations":{"interlink.autolauncher/mode":"local","interlink.autolauncher/target":"local"}},
      "spec": {
        "containers":[
          {"name":"c","image":"busybox:1.36","command":["sh","-c"],"args":["echo start; sleep 5; echo done"]}
        ]
      }
    },
    "container":[]
  }
]
JSON

echo "CREATE:"
curl -sS -X POST "$EP/create" -H 'Content-Type: application/json' --data-binary @/tmp/create.json
echo -e "\nSTATUS:"
curl -sS -X GET "$EP/status" -H 'Content-Type: application/json' \
  --data-binary '[{"metadata":{"name":"hello","uid":"uid-long","namespace":"default"},"spec":{"containers":[{"name":"c","image":"busybox:1.36"}]}}]'
echo -e "\nLOGS:"
curl -sS -X GET "$EP/getLogs" -H 'Content-Type: application/json' \
  --data-binary '{"PodUID":"uid-long","Namespace":"default","PodName":"hello","ContainerName":"c","Opts":{"Tail":1000,"Timestamps":false,"Previous":false}}'
echo -e "\nDELETE:"
curl -sS -X POST "$EP/delete" -H 'Content-Type: application/json' \
  --data-binary '{"metadata":{"name":"hello","uid":"uid-long","namespace":"default"},"spec":{"containers":[{"name":"c","image":"busybox:1.36"}],"initContainers":[]}}'
echo
