#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <autolauncher-host-or-ip> <ssh-user-on-autolauncher> <node-name> [ssh-key-path]"
  echo "  Or set AL_SSH_KEY=/path/to/key.pem in the environment."
}

if [[ $# -lt 3 ]]; then
  usage
  exit 1
fi

AL_HOST="$1"
AL_USER="$2"
NODE_NAME="$3"
AL_SSH_KEY="${4:-${AL_SSH_KEY:-}}"

REAL_USER="${SUDO_USER:-$USER}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
if [[ -n "${AL_SSH_KEY}" ]]; then
  if [[ ! -f "${AL_SSH_KEY}" ]]; then
    echo "ERROR: SSH key '${AL_SSH_KEY}' not found." >&2
    exit 2
  fi
  chmod 600 "${AL_SSH_KEY}" || true
  SSH_OPTS="${SSH_OPTS} -i ${AL_SSH_KEY} -o IdentitiesOnly=yes"
fi

echo "==> Installing Helm (if missing)"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
fi

echo "==> Fetching InterLink values.yaml from autolauncher (${AL_USER}@${AL_HOST})"
if [[ "$(id -u)" -eq 0 ]]; then
  sudo -u "${REAL_USER}" scp ${SSH_OPTS} "${AL_USER}@${AL_HOST}:~/.interlink/manifests/values.yaml" /tmp/interlink-values.yaml
else
  scp ${SSH_OPTS} "${AL_USER}@${AL_HOST}:~/.interlink/manifests/values.yaml" /tmp/interlink-values.yaml
fi

# Override to REST toward autolauncher:30433 and set the virtual node name
cat >/tmp/interlink-overrides.yaml <<YAML
OAUTH:
  enabled: false
interlink:
  address: http://${AL_HOST}
  port: 30433
nodeName: ${NODE_NAME}
YAML

# Chart locations
OCI_CHART="oci://ghcr.io/intertwin-eu/interlink-helm-chart/interlink"
# If you know a specific version you want, export INTERLINK_CHART_VERSION; default to 0.4.1
INTERLINK_CHART_VERSION="${INTERLINK_CHART_VERSION:-0.4.1}"
GIT_REPO_URL="https://github.com/interlink-hq/interlink-helm-chart.git"
GIT_CLONE_DIR="/tmp/interlink-helm-chart"

install_from_git() {
  echo "==> Falling back to Git chart (${GIT_REPO_URL})"
  rm -rf "${GIT_CLONE_DIR}"
  git clone "${GIT_REPO_URL}" "${GIT_CLONE_DIR}"
  helm upgrade --install \
    --create-namespace \
    -n interlink \
    "${NODE_NAME}" \
    "${GIT_CLONE_DIR}/interlink" \
    --values /tmp/interlink-values.yaml \
    --values /tmp/interlink-overrides.yaml
}

echo "==> Installing/Upgrading InterLink Helm chart (OCI first)"
set +e
helm upgrade --install \
  --create-namespace \
  -n interlink \
  "${NODE_NAME}" \
  "${OCI_CHART}" \
  --version "${INTERLINK_CHART_VERSION}" \
  --values /tmp/interlink-values.yaml \
  --values /tmp/interlink-overrides.yaml
OCI_RC=$?
set -e

if [[ $OCI_RC -ne 0 ]]; then
  echo "WARN: OCI install failed (code ${OCI_RC}). This can happen if GHCR requires auth or the package path differs."
  echo "      Trying source install from GitHub instead…"
  install_from_git
fi

echo "==> Waiting a few seconds for the virtual node to register"
sleep 5
kubectl get nodes -o wide || true

echo "==> Deploying a tiny smoke test Pod"
kubectl create namespace interlink --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: interlink-smoketest
  namespace: interlink
spec:
  nodeSelector:
    kubernetes.io/hostname: ${NODE_NAME}
  tolerations:
    - key: virtual-node.interlink/no-schedule
      operator: Exists
  containers:
  - name: test
    image: busybox
    command: ["sh","-lc","echo hello-from-interlink; sleep 10"]
  restartPolicy: Never
EOF

echo "==> Pod status:"
kubectl -n interlink get pod interlink-smoketest -o wide || true

echo "==> If 'kubectl logs' fails, approve CSR (once):"
echo "   kubectl get csr"
echo "   kubectl certificate approve <csr-name>"
