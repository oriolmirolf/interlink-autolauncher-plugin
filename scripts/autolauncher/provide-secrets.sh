#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="interlink-autolauncher-plugin"
SECRETS_DIR="/etc/interlink-autolauncher-plugin"
SECRETS_FILE="${SECRETS_DIR}/secrets.env"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
DROPIN_FILE="${DROPIN_DIR}/10-env.conf"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options]

Options (all optional; you can provide any subset):
  --mn5-acc-password <pwd>       Set MN5 ACC password (env: MN5_ACC_PASSWORD)
  --mn5-acc-key-passphrase <pp>  Set passphrase for encrypted SSH key (env: MN5_ACC_KEY_PASSPHRASE)
  --cesga-password <pwd>         Set CESGA password (env: CESGA_PASSWORD)
  --mn5-pw <pwd>                 Alias for --mn5-acc-password
  --restart                      Restart the plugin after writing secrets (default)
  --no-restart                   Do not restart; just write files
  -h, --help

If a value is not provided, the script will prompt securely.

Examples:
  $(basename "$0") --mn5-acc-password 's3cr3t'
  $(basename "$0") --mn5-acc-password 's3cr3t' --cesga-password 'c3sg@PW'
EOF
}

# Defaults
RESTART=1
MN5_PW=""
MN5_KEY_PP=""
CESGA_PW=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mn5-acc-password|--mn5-pw) shift; MN5_PW="${1-}";;
    --mn5-acc-key-passphrase)     shift; MN5_KEY_PP="${1-}";;
    --cesga-password)             shift; CESGA_PW="${1-}";;
    --restart)                    RESTART=1;;
    --no-restart)                 RESTART=0;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
  shift || true
done

# Prompt if missing
prompt_secret() {
  local varname="$1" prompt="$2"
  local -n ref="$varname"
  if [[ -z "${ref}" ]]; then
    read -r -s -p "${prompt}: " ref
    echo
  fi
}

[[ -n "${MN5_PW}"     ]] || prompt_secret MN5_PW     "Enter MN5 ACC password (blank to skip)"
[[ -n "${CESGA_PW}"   ]] || prompt_secret CESGA_PW   "Enter CESGA password (blank to skip)"
[[ -n "${MN5_KEY_PP}" ]] || prompt_secret MN5_KEY_PP "Enter MN5 key passphrase (blank if key not encrypted)"

# Ensure dirs
sudo install -d -m 750 "${SECRETS_DIR}"
sudo install -d -m 755 "${DROPIN_DIR}"

# Create drop-in (idempotent)
if [[ ! -f "${DROPIN_FILE}" ]]; then
  sudo tee "${DROPIN_FILE}" >/dev/null <<EOF
[Service]
EnvironmentFile=-${SECRETS_FILE}
EOF
fi

# Helper: upsert VAR='value' (quoted safely)
upsert_env() {
  local var="$1" val="$2"
  [[ -n "${val}" ]] || return 0
  # Escape single quotes in value for single-quoted assignment
  local esc="${val//\'/\''\"'\"'\'}"
  if [[ -f "${SECRETS_FILE}" ]] && sudo grep -qE "^${var}=" "${SECRETS_FILE}"; then
    sudo sed -i -E "s|^${var}=.*$|${var}='${esc}'|" "${SECRETS_FILE}"
  else
    sudo bash -c "echo ${var}='${esc}' >> '${SECRETS_FILE}'"
  fi
}

# Touch file if missing; lock down perms
if [[ ! -f "${SECRETS_FILE}" ]]; then
  sudo install -m 600 /dev/null "${SECRETS_FILE}"
fi
sudo chown root:root "${SECRETS_FILE}"

# Write requested vars
upsert_env "MN5_ACC_PASSWORD"       "${MN5_PW}"
upsert_env "MN5_ACC_KEY_PASSPHRASE" "${MN5_KEY_PP}"
upsert_env "CESGA_PASSWORD"         "${CESGA_PW}"

# Permissions again (in case sed changed)
sudo chmod 600 "${SECRETS_FILE}"

echo "Wrote secrets to ${SECRETS_FILE}"
echo "Drop-in file: ${DROPIN_FILE}"

# Reload/restart if requested
if [[ "${RESTART}" == "1" ]]; then
  echo "Reloading systemd and restarting ${SERVICE_NAME}..."
  sudo systemctl daemon-reload
  sudo systemctl restart "${SERVICE_NAME}"
  sleep 1
  sudo systemctl status "${SERVICE_NAME}" --no-pager || true
  echo "Recent logs:"
  journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true
else
  echo "Skipping restart (--no-restart)."
fi

echo "Done."