#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="interlink-autolauncher-plugin"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

sudo systemctl disable --now "${SERVICE_NAME}" || true
sudo rm -f "${SERVICE_FILE}"
sudo systemctl daemon-reload
echo "Unit removed."