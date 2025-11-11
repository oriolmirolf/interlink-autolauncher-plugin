#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-interlink}"
NODE_NAME="${NODE_NAME:-slurm-edge}"

INTERLINK_IP="${INTERLINK_IP:-212.128.226.224}"
INTERLINK_PORT="${INTERLINK_PORT:-30433}"

CHART="${CHART:-oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink}"
CHART_VER="${CHART_VER:-0.5.3-pre1}"

CPUS="${CPUS:-2}"
MEM_GIB="${MEM_GIB:-6}"
PODS="${PODS:-10}"

# prereqs
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need kubectl
need helm
need awk
need sed

echo "[INFO] Target InterLink: http://${INTERLINK_IP}:${INTERLINK_PORT}"
echo "[INFO] Installing node '${NODE_NAME}' into namespace '${NAMESPACE}'"

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

# values file
VALUES_FILE="$(mktemp -t interlink-values.XXXX.yaml)"
cat > "${VALUES_FILE}" <<EOF
nodeName: ${NODE_NAME}
interlink:
  address: "http://${INTERLINK_IP}"
  port: ${INTERLINK_PORT}
OAUTH:
  enabled: false
virtualNode:
  resources: { CPUs: ${CPUS}, memGiB: ${MEM_GIB}, pods: ${PODS} }
EOF
echo "[INFO] Wrote values to ${VALUES_FILE}"

helm upgrade --install -n "${NAMESPACE}" --create-namespace "${NODE_NAME}" \
  "${CHART}" --version "${CHART_VER}" -f "${VALUES_FILE}"

kubectl -n "${NAMESPACE}" rollout status deploy/${NODE_NAME}-node --timeout=5m

# CSR approvals! so kubectl logs/exec work
echo "[INFO] Approving pending kubelet-serving CSRs (best-effort)…"
for i in {1..20}; do
  kubectl get csr | awk '/Pending/ {print $1}' | xargs -r kubectl certificate approve || true
  sleep 2
done

echo "[INFO] Checking Node/${NODE_NAME} readiness…"
for i in {1..60}; do
  READY="$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "${READY}" = "True" ]; then
    echo "[OK] Node is Ready."
    break
  fi
  sleep 2
done

kubectl get nodes -o wide | grep -E "NAME|${NODE_NAME}"

# sanity test
echo "[INFO] Launching a tiny sanity pod on ${NODE_NAME}…"
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: hello-slurm
  namespace: interlink
spec:
  nodeSelector:
    kubernetes.io/hostname: slurm-edge
  tolerations:
    - key: virtual-node.interlink/no-schedule
      operator: Exists
  restartPolicy: Never
  containers:
  - name: hello
    image: busybox:1.36
    command: ["sh","-c","echo Node=$(hostname); echo OK && sleep 1"]
    resources:
      requests: { cpu: "250m", memory: "128Mi" }
      limits:   { cpu: "500m", memory: "256Mi" }
EOF

kubectl -n interlink wait pod/hello-slurm --for=condition=Succeeded --timeout=5m || true
echo "----- hello-slurm logs -----"
kubectl -n interlink logs pod/hello-slurm || {
  echo "[WARN] If logs fail, approve CSRs again:  kubectl get csr ; kubectl certificate approve <name>"
}
echo "----------------------------"

echo "[DONE] Remote InterLink node '${NODE_NAME}' is installed."
