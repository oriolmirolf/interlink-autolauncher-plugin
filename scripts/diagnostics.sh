#!/usr/bin/env bash
set -euo pipefail

# Detect the plugin user from systemd (fallbacks to $SUDO_USER or current user)
PLUGIN_USER="$(systemctl show autolauncher-plugin -p User --value 2>/dev/null || true)"
PLUGIN_USER="${PLUGIN_USER:-${SUDO_USER:-$USER}}"
HOME_DIR="/home/${PLUGIN_USER}"

PLUGIN_SOCK="${HOME_DIR}/.interlink/.plugin.sock"
INTERLINK_SOCK="${HOME_DIR}/.interlink/.interlink.sock"

echo "==> Plugin socket:"
[[ -S "${PLUGIN_SOCK}" ]] && echo "  OK ${PLUGIN_SOCK}" || echo "  MISSING ${PLUGIN_SOCK}"

echo "==> Plugin /health:"
sudo -u "${PLUGIN_USER}" curl -sSf --unix-socket "${PLUGIN_SOCK}" http://unix/health || true; echo

echo "==> InterLink pinglink:"
sudo -u "${PLUGIN_USER}" curl -sSf --unix-socket "${INTERLINK_SOCK}" http://unix/pinglink || true; echo

echo "==> Systemd units:"
systemctl --no-pager --full status autolauncher-plugin.service | sed -n '1,30p' || true
systemctl --no-pager --full status interlink-uds2tcp.service | sed -n '1,30p' || true
