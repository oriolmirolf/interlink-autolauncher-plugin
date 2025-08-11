#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="worker-plugin-bridge"
SOCKET_PATH="/var/run/interlink/.plugin.sock"

sudo systemctl stop "${SERVICE_NAME}" || true
sudo pkill -f 'socat .*\.plugin\.sock' || true
sudo rm -f "${SOCKET_PATH}" || true
sudo systemctl daemon-reload
sudo systemctl restart "${SERVICE_NAME}"
sleep 1
systemctl status "${SERVICE_NAME}" --no-pager || true
ls -l "${SOCKET_PATH}" || true
curl -sSf --unix-socket "${SOCKET_PATH}" http://unix/health && echo