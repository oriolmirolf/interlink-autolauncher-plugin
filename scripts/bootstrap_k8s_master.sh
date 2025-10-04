#!/usr/bin/env bash
set -euo pipefail

AUTOLAUNCHER_HOST="${1:-192.168.0.98}"
AUTOLAUNCHER_USER="${2:-$USER}"
NODE_NAME="${3:-autolauncher-edge}"

echo "==> Checking kubectl & helm"
if ! command -v kubectl >/dev/null; then
  echo "kubectl not found. Please install kubectl first."
  exit 1
fi
if ! command -v helm >/dev/null; then
  echo "Installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "==> Fetching Helm values from autolauncher (${AUTOLAUNCHER_USER}@${AUTOLAUNCHER_HOST})"
mkdir -p /tmp/interlink-values
scp "${AUTOLAUNCHER_USER}@${AUTOLAUNCHER_HOST}:~/.interlink/manifests/values.yaml" /tmp/interlink-values/values.yaml

cat >/tmp/interlink-values/override-no-oauth.yaml <<EOF
nodeName: ${NODE_NAME}
OAUTH:
  enabled: false
interlink:
  address: http://${AUTOLAUNCHER_HOST}
  port: 30433
EOF

echo "==> Install/upgrade InterLink Helm chart (no-OAuth override)"
export INTERLINK_CHART_VERSION=$(curl -s https://api.github.com/repos/interlink-hq/interlink-helm-chart/releases/latest | jq -r .name)
helm upgrade --install \
  --create-namespace \
  -n interlink \
  ${NODE_NAME} \
  oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink \
  --version ${INTERLINK_CHART_VERSION} \
  --values /tmp/interlink-values/values.yaml \
  --values /tmp/interlink-values/override-no-oauth.yaml

echo "==> Wait for the virtual node to become Ready"
set +e
for i in {1..60}; do
  if kubectl get nodes | grep -q "${NODE_NAME}"; then
    break
  fi
  sleep 3
done
set -e
kubectl get nodes

echo "==> Apply test pod"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-tunnel
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
    command: ["sh","-lc"]
    args: ["echo hello from interlink; sleep 20"]
EOF

echo "==> If logs fail, you may need to approve CSR:"
echo "kubectl get csr"
