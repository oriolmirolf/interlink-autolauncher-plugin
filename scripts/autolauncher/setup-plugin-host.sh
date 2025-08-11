#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/interlink-autolauncher-plugin}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SERVICE_NAME="interlink-autolauncher-plugin"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="/var/lib/interlink-autolauncher-plugin"
PORT="${PORT:-8001}"
HOST="${HOST:-0.0.0.0}"
CONF_DIR="/etc/interlink-autolauncher-plugin"
TARGETS_DST="${CONF_DIR}/targets.yml"

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

echo "==> Installing targets.yml to ${TARGETS_DST}"
sudo mkdir -p "${CONF_DIR}"
if [ -f "${REPO_DIR}/targets.yml" ]; then
  sudo cp -f "${REPO_DIR}/targets.yml" "${TARGETS_DST}"
else
  echo "[WARN] ${REPO_DIR}/targets.yml not found; HPC mode will fail until one is installed at ${TARGETS_DST}"
fi

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
Environment=PLUGIN_STATE_PATH=${STATE_DIR}/state.json
Environment=AUTOLAUNCHER_LOCAL_PATH=${REPO_DIR}/vendor/autolauncher/autolauncher.py
Environment=PLUGIN_TARGETS_FILE=${TARGETS_DST}
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