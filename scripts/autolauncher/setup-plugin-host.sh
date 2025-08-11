#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/interlink-autolauncher-plugin}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_NAME="interlink-autolauncher-plugin"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="/var/lib/interlink-autolauncher-plugin"
PORT="${PORT:-8001}"
HOST="${HOST:-0.0.0.0}"

echo "==> Ensuring base packages"
sudo apt-get update -y
sudo apt-get install -y python3-venv python3-pip git curl

echo "==> Preparing virtualenv"
cd "$REPO_DIR"
[ -d .venv ] || ${PYTHON_BIN} -m venv .venv
. .venv/bin/activate
pip install --upgrade pip wheel
if [ -f requirements.txt ]; then
  pip install -r requirements.txt
fi

echo "==> Creating state dir ${STATE_DIR}"
sudo mkdir -p "${STATE_DIR}"
sudo chown -R "$USER:$USER" "${STATE_DIR}"

echo "==> Writing systemd unit ${SERVICE_FILE}"
sudo tee "${SERVICE_FILE}" >/dev/null <<UNIT
[Unit]
Description=Interlink Autolauncher Plugin (host Python)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=PLUGIN_MODE=local
Environment=PLUGIN_STATE_DIR=${STATE_DIR}
ExecStart=${REPO_DIR}/.venv/bin/uvicorn main:app --host ${HOST} --port ${PORT}
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Reloading and starting service"
sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}"

echo "==> Waiting for port ${PORT}"
sleep 1
if ! ss -lnt "( sport = :${PORT} )" | grep -q ":${PORT}"; then
  echo "Service not listening yet; checking logs..."
  journalctl -u "${SERVICE_NAME}" -n 100 --no-pager || true
  exit 1
fi

echo "==> Health check"
curl -sSf "http://127.0.0.1:${PORT}/health" && echo
echo "OK."