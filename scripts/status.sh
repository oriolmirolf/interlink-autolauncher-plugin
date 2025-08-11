#!/usr/bin/env bash
set -euo pipefail
EP="${1:-http://127.0.0.1:8001}"
UID="${2:-uid-long}"
curl -sS -X GET "$EP/status" -H 'Content-Type: application/json' \
  --data-binary "[{\"metadata\":{\"name\":\"hello\",\"uid\":\"$UID\",\"namespace\":\"default\"},\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":\"busybox:1.36\"}]}}]"
echo
