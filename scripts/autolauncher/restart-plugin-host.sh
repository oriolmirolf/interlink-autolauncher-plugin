#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="interlink-autolauncher-plugin"
sudo systemctl restart "${SERVICE_NAME}"
sleep 1
sudo systemctl status "${SERVICE_NAME}" --no-pager || true