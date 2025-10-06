#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <AUTOLAUNCHER_IP> <ssh-user-on-autolauncher> <node-name> [ssh-key]" >&2
  exit 1
fi

AL_HOST="$1"; AL_USER="$2"; NODE_NAME="$3"; AL_SSH_KEY="${4:-}"
REAL_USER="${SUDO_USER:-$USER}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
[[ -n "${AL_SSH_KEY}" ]] && SSH_OPTS="${SSH_OPTS} -i ${AL_SSH_KEY} -o IdentitiesOnly=yes"

# Helm if missing
if ! command -v helm >/dev/null 2>&1; then curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash; fi

# Pull values generated on autolauncher
if [[ "$(id -u)" -eq 0 ]]; then
  sudo -u "${REAL_USER}" scp ${SSH_OPTS} "${AL_USER}@${AL_HOST}:~/.interlink/manifests/values.yaml" /tmp/interlink-values.yaml
else
  scp ${SSH_OPTS} "${AL_USER}@${AL_HOST}:~/.interlink/manifests/values.yaml" /tmp/interlink-values.yaml
fi

# Override to REST against http://<autolauncher>:30433
cat >/tmp/interlink-overrides.yaml <<YAML
OAUTH:
  enabled: false
interlink:
  address: http://${AL_HOST}
  port: 30433
nodeName: ${NODE_NAME}
YAML

# Try OCI chart first (current release train)
OCI_CHART="oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink"
INTERLINK_CHART_VERSION="${INTERLINK_CHART_VERSION:-0.5.2}"
set +e
helm upgrade --install \
  --create-namespace \
  -n interlink \
  "${NODE_NAME}" \
  "${OCI_CHART}" \
  --version "${INTERLINK_CHART_VERSION}" \
  --values /tmp/interlink-values.yaml \
  --values /tmp/interlink-overrides.yaml
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  echo "OCI install failed, falling back to Git checkout..."
  git clone https://github.com/interlink-hq/interlink-helm-chart /tmp/interlink-helm-chart
  helm upgrade --install \
    --create-namespace \
    -n interlink \
    "${NODE_NAME}" \
    /tmp/interlink-helm-chart/interlink \
    --values /tmp/interlink-values.yaml \
    --values /tmp/interlink-overrides.yaml
fi

sleep 5
kubectl get nodes -o wide || true
# Avoid kubelet port collision for VK
kubectl -n interlink set env deploy/${NODE_NAME}-node KUBELET_PORT=20250
kubectl -n interlink rollout status deploy/${NODE_NAME}-node

# smoke test
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

echo "If 'kubectl logs' fails, approve CSR once:"
echo "  kubectl get csr"
echo "  kubectl certificate approve <csr-name>"
