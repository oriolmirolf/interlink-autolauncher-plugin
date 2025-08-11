#!/usr/bin/env bash
set -euo pipefail

TARGET_IP="${1:-}"
TARGET_PORT="${2:-8001}"
[ -n "${TARGET_IP}" ] || { echo "Usage: $0 <AUTOLAUNCHER_IP> [PORT]"; exit 1; }

SERVICE_NAME="worker-plugin-bridge"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SOCKET_DIR="/var/run/interlink"
SOCKET_PATH="${SOCKET_DIR}/.plugin.sock"

echo "==> Installing socat"
sudo apt-get update -y
sudo apt-get install -y socat curl

echo "==> Writing systemd unit ${SERVICE_FILE}"
sudo tee "${SERVICE_FILE}" >/dev/null <<UNIT
[Unit]
Description=Worker bridge: ${SOCKET_PATH} -> ${TARGET_IP}:${TARGET_PORT}
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/usr/bin/mkdir -p ${SOCKET_DIR}
ExecStartPre=/usr/bin/rm -f ${SOCKET_PATH}
ExecStart=/usr/bin/socat UNIX-LISTEN:${SOCKET_PATH},fork,mode=666 TCP:${TARGET_IP}:${TARGET_PORT}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Reloading and starting service"
sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

echo "==> Verifying UNIX socket exists"
sleep 1
ls -l "${SOCKET_PATH}"

echo "==> Health check through UNIX socket"
curl -sSf --unix-socket "${SOCKET_PATH}" http://unix/health && echo
echo "OK."