#!/usr/bin/env bash
set -euo pipefail

# This script runs on the K8s master node.
# It installs helm (if missing) and deploys the InterLink Helm chart using values generated on the autolauncher node.

AUTOLAUNCHER_HOST="${1:-192.168.0.98}"
AUTOLAUNCHER_USER="${2:-$USER}"

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

echo "==> Install/upgrade InterLink Helm chart"
export INTERLINK_CHART_VERSION=$(curl -s https://api.github.com/repos/interlink-hq/interlink-helm-chart/releases/latest | jq -r .name)
helm upgrade --install \
  --create-namespace \
  -n interlink \
  my-node \
  oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink \
  --version ${INTERLINK_CHART_VERSION} \
  --values /tmp/interlink-values/values.yaml

echo "==> Wait for the virtual node to become Ready"
kubectl get nodes -w | awk '/virtual-kubelet/{print; exit}'

echo "==> Apply test pod"
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-tunnel
spec:
  nodeSelector:
    kubernetes.io/hostname: my-node
  tolerations:
    - key: virtual-node.interlink/no-schedule
      operator: Exists
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]
EOF

echo "==> If logs fail, you may need to approve CSR:"
echo "kubectl get csr"
