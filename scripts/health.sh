#!/usr/bin/env bash
set -euo pipefail
EP="${1:-http://127.0.0.1:8001}"
curl -sS "$EP/health"
echo
