#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="worker-plugin-bridge"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SOCKET_PATH="/var/run/interlink/.plugin.sock"

sudo systemctl disable --now "${SERVICE_NAME}" || true
sudo rm -f "${SERVICE_FILE}"
sudo systemctl daemon-reload
sudo rm -f "${SOCKET_PATH}" || true
echo "Bridge unit removed."
