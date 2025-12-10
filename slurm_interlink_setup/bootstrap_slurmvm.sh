#!/usr/bin/env bash
set -Eeuo pipefail

### =======================
### Configuration (override via env vars)
### =======================
INTERLINK_HOST="${INTERLINK_HOST:-0.0.0.0}"        # Bind address for TCP bridge
INTERLINK_PORT="${INTERLINK_PORT:-30433}"          # TCP bridge port (from K8s)
IL_VERSION="${IL_VERSION:-0.5.1}"                  # interLink API version to run
PLUGIN_VERSION="${PLUGIN_VERSION:-}"               # Leave empty to auto-detect latest
NODE_NAME="${NODE_NAME:-slurm-edge}"               # Cosmetic; shows in logs only
DATA_ROOT="${DATA_ROOT:-$HOME/.interlink/jobs}"    # Shared path visible to SLURM nodes
SBATCH_PATH="${SBATCH_PATH:-/usr/bin/sbatch}"
SCANCEL_PATH="${SCANCEL_PATH:-/usr/bin/scancel}"
SQUEUE_PATH="${SQUEUE_PATH:-/usr/bin/squeue}"
IMAGE_PREFIX="${IMAGE_PREFIX:-docker://}"          # For Singularity/Apptainer
BASH_PATH="${BASH_PATH:-/bin/bash}"                # Ensures scripts get a proper shebang

### =======================
### Internal paths
### =======================
IL_DIR="$HOME/.interlink"
BIN_DIR="$IL_DIR/bin"
LOG_DIR="$IL_DIR/logs"
MAN_DIR="$IL_DIR/manifests"
SOCK_INTERLINK="$IL_DIR/.interlink.sock"
SOCK_PLUGIN="$IL_DIR/.plugin.sock"
PLUGIN_CFG="$MAN_DIR/plugin-config.yaml"

### =======================
### Helpers
### =======================
die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command '$1'"; }
require_not_root() { [ "${EUID:-$(id -u)}" -ne 0 ] || die "Run as a regular user (not root)."; }

latest_tag() {
  # Usage: latest_tag owner/repo
  local repo="$1"
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${repo}/releases/latest")" || return 1
  echo "${url}" | sed -E 's@.*/tag/([^/]+)@\1@'
}

wait_for_socket() {
  local sock="$1" timeout="${2:-30}"
  while ((timeout-- > 0)); do
    [ -S "$sock" ] && return 0
    sleep 1
  done
  return 1
}

kill_if_running() {
  local pattern="$1"
  pkill -f "$pattern" >/dev/null 2>&1 || true
}

### =======================
### Pre-flight
### =======================
require_not_root
need_cmd curl
need_cmd sed
need_cmd grep
# Install socat if missing (Ubuntu/Debian)
if ! command -v socat >/dev/null 2>&1; then
  echo "[INFO] Installing socat ..."
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -y -qq && sudo apt-get install -y -qq socat
  else
    die "Please install 'socat' or rerun with sudo available."
  fi
fi

mkdir -p "$BIN_DIR" "$LOG_DIR" "$MAN_DIR" "$DATA_ROOT"

echo "[INFO] Using:"
echo "  InterLink version : $IL_VERSION"
if [ -z "$PLUGIN_VERSION" ]; then
  PLUGIN_VERSION="$(latest_tag interlink-hq/interlink-slurm-plugin)" || die "Cannot auto-detect plugin version"
  echo "  SLURM plugin tag  : $PLUGIN_VERSION (latest)"
else
  echo "  SLURM plugin tag  : $PLUGIN_VERSION (from env)"
fi
echo "  TCP bridge        : http://${INTERLINK_HOST}:${INTERLINK_PORT}"
echo "  Sockets           : API=$SOCK_INTERLINK  Plugin=$SOCK_PLUGIN"
echo "  Data root         : $DATA_ROOT"

# Friendly SLURM hints
if ! command -v squeue >/dev/null 2>&1; then
  echo "[WARN] SLURM not detected in PATH. Ensure slurmctld/slurmd are installed & running."
fi
for p in "$SBATCH_PATH" "$SCANCEL_PATH" "$SQUEUE_PATH"; do
  [ -x "$p" ] || echo "[WARN] Expected SLURM binary not found: $p"
done
if grep -q '^AccountingStorageEnforce=' /etc/slurm/slurm.conf 2>/dev/null; then
  echo "[WARN] /etc/slurm/slurm.conf contains AccountingStorageEnforce=…; remove this line if not using slurmdbd."
fi

### =======================
### Write/refresh plugin config
### =======================
cat >"$PLUGIN_CFG" <<EOF
Socket: "unix://$SOCK_PLUGIN"
DataRootFolder: "$DATA_ROOT/"
SbatchPath: "$SBATCH_PATH"
ScancelPath: "$SCANCEL_PATH"
SqueuePath: "$SQUEUE_PATH"
ImagePrefix: "$IMAGE_PREFIX"
BashPath: "$BASH_PATH"
VerboseLogging: true
ErrorsOnlyLogging: false
CommandPrefix: ""
EOF
echo "[INFO] Wrote plugin config: $PLUGIN_CFG"

### =======================
### Download/refresh binaries
### =======================
# interLink API binary
if [ ! -x "$BIN_DIR/interlink" ]; then
  echo "[INFO] Downloading interLink API $IL_VERSION ..."
  curl -fsSL "https://github.com/interlink-hq/interLink/releases/download/${IL_VERSION}/interlink_Linux_x86_64" -o "$BIN_DIR/interlink"
  chmod +x "$BIN_DIR/interlink"
fi

# SLURM plugin binary
if [ ! -x "$BIN_DIR/interlink-slurm-plugin" ]; then
  echo "[INFO] Downloading SLURM plugin $PLUGIN_VERSION ..."
  curl -fsSL "https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/${PLUGIN_VERSION}/interlink-sidecar-slurm_Linux_x86_64" \
    -o "$BIN_DIR/interlink-slurm-plugin"
  chmod +x "$BIN_DIR/interlink-slurm-plugin"
fi

### =======================
### Start plugin first (creates .plugin.sock)
### =======================
echo "[INFO] Starting SLURM plugin ..."
rm -f "$SOCK_PLUGIN"
export SLURMCONFIGPATH="$PLUGIN_CFG"
nohup "$BIN_DIR/interlink-slurm-plugin" > "$LOG_DIR/plugin.log" 2>&1 &
sleep 1
if wait_for_socket "$SOCK_PLUGIN" 20; then
  echo "[OK] Plugin socket up: $SOCK_PLUGIN"
else
  echo "[ERR] Plugin socket did not appear. Tail follows:"
  tail -n 200 "$LOG_DIR/plugin.log" || true
  exit 1
fi

### =======================
### Start interLink API (creates .interlink.sock)
### =======================
echo "[INFO] Starting interLink API ..."
rm -f "$SOCK_INTERLINK"
nohup "$BIN_DIR/interlink" > "$LOG_DIR/interlink.log" 2>&1 &
sleep 1
if wait_for_socket "$SOCK_INTERLINK" 20; then
  echo "[OK] API socket up: $SOCK_INTERLINK"
else
  echo "[ERR] API socket did not appear. Tail follows:"
  tail -n 200 "$LOG_DIR/interlink.log" || true
  exit 1
fi

### =======================
### Start/refresh TCP bridge :${INTERLINK_PORT} -> UNIX socket
### =======================
echo "[INFO] (Re)starting TCP bridge on ${INTERLINK_HOST}:${INTERLINK_PORT} ..."
kill_if_running "socat .* TCP-LISTEN:${INTERLINK_PORT}"
nohup socat -d -d "TCP-LISTEN:${INTERLINK_PORT},fork,bind=${INTERLINK_HOST}" "UNIX-CONNECT:${SOCK_INTERLINK}" \
  > "$LOG_DIR/socat.log" 2>&1 &
sleep 1

### =======================
### Health checks
### =======================
echo "[INFO] Local health via UNIX socket:"
curl -fsS --unix-socket "$SOCK_INTERLINK" http://unix/pinglink | sed 's/^/[API] /' || true

echo "[INFO] Health via TCP bridge:"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://${INTERLINK_HOST}:${INTERLINK_PORT}/pinglink" || true)"
echo "[INFO] /pinglink over TCP returned HTTP ${HTTP_CODE}"
[ "$HTTP_CODE" = "200" ] || echo "[WARN] /pinglink != 200 yet; check logs in $LOG_DIR (plugin/interlink/socat)."

echo "[DONE] SLURM VM setup complete."
echo "       From K8s side, point the Helm chart to: http://${INTERLINK_HOST}:${INTERLINK_PORT}"
