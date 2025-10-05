#!/usr/bin/env bash
set -euo pipefail

PLUGIN_SOCK="${HOME}/.interlink/.plugin.sock"
INTERLINK_SOCK="${HOME}/.interlink/.interlink.sock"

echo "==> Plugin socket:"
[[ -S "${PLUGIN_SOCK}" ]] && echo "  OK ${PLUGIN_SOCK}" || echo "  MISSING ${PLUGIN_SOCK}"

echo "==> Plugin /health:"
curl -sSf --unix-socket "${PLUGIN_SOCK}" http://unix/health || true; echo

echo "==> InterLink pinglink:"
curl -sSf --unix-socket "${INTERLINK_SOCK}" http://unix/pinglink || true; echo

echo "==> Systemd units:"
systemctl --no-pager --full status autolauncher-plugin.service | sed -n '1,30p' || true
systemctl --no-pager --full status interlink-uds2tcp.service | sed -n '1,30p' || true
