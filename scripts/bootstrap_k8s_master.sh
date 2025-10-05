#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <autolauncher-ip> <ssh-user-on-autolauncher> <node-name>"
  exit 1
fi

AL_IP="$1"
AL_USER="$2"
NODE_NAME="$3"

echo "==> Installing Helm (if missing)"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "==> Fetching InterLink values.yaml from autolauncher"
scp -o StrictHostKeyChecking=no "${AL_USER}@${AL_IP}:~/.interlink/manifests/values.yaml" /tmp/interlink-values.yaml

# Create an override for no-OAuth, REST to autolauncher:30433 and node name
cat >/tmp/interlink-overrides.yaml <<YAML
OAUTH:
  enabled: false
interlink:
  address: http://${AL_IP}
  port: 30433
nodeName: ${NODE_NAME}
YAML

echo "==> Installing/Upgrading InterLink Helm chart"
export INTERLINK_CHART_VERSION=$(helm show chart oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink | awk '/version:/ {print $2}')
helm upgrade --install \
  --create-namespace \
  -n interlink \
  "${NODE_NAME}" \
  oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink \
  --version "${INTERLINK_CHART_VERSION}" \
  --values /tmp/interlink-values.yaml \
  --values /tmp/interlink-overrides.yaml

echo "==> Waiting for virtual node to appear (this may take a bit)"
sleep 5
kubectl get nodes -o wide

echo "==> Deploying a tiny test Pod"
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
kubectl -n interlink get pod interlink-smoketest -o wide
