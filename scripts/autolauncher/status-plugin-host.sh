#!/usr/bin/env bash
set -euo pipefail
SERVICE_NAME="interlink-autolauncher-plugin"
sudo systemctl status "${SERVICE_NAME}" --no-pager || true
sudo ss -lntp | grep -E ':8001\b' || true
