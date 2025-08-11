#!/usr/bin/env bash
set -euo pipefail
EP="${1:-http://127.0.0.1:8001}"
UID="${2:-uid-long}"
curl -sS -X GET "$EP/getLogs" -H 'Content-Type: application/json' \
  --data-binary "{\"PodUID\":\"$UID\",\"Namespace\":\"default\",\"PodName\":\"hello\",\"ContainerName\":\"c\",\"Opts\":{\"Tail\":1000,\"Timestamps\":false,\"Previous\":false}}"
echo
