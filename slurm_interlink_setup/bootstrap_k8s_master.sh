#!/usr/bin/env bash
set -Eeuo pipefail

### =======================
### Configuration (override via env vars)
### =======================
INTERLINK_HOST="${INTERLINK_HOST:-192.168.0.3}"        # SLURM VM IP/host
INTERLINK_PORT="${INTERLINK_PORT:-30433}"
NODE_NAME="${NODE_NAME:-slurm-edge}"
NAMESPACE="${NAMESPACE:-interlink}"

CHART="${CHART:-oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink}"
CHART_VER="${CHART_VER:-0.5.3-pre1}"   # newer default; override as needed

# Virtual node capacity (adjust as you like)
CPUS="${CPUS:-2}"
MEM_GIB="${MEM_GIB:-6}"
PODS="${PODS:-10}"

# Kubelet port to use IF hostNetwork=true (avoid 10250 clash)
KUBELET_PORT="${KUBELET_PORT:-20250}"

# Optional: auto-approve Serving CSRs coming from this SA
AUTO_APPROVE_CSR="${AUTO_APPROVE_CSR:-false}"

### =======================
### Helpers
### =======================
die() { echo "ERROR: $*" >&2; exit 1; }

pick_kubectl() {
  if kubectl version --client >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    echo "kubectl"; return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo kubectl version --client >/dev/null 2>&1 && sudo kubectl cluster-info >/dev/null 2>&1; then
    echo "sudo kubectl"; return 0
  fi
  return 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command '$1'"; }

approve_csrs() {
  local K="$1"
  local name
  mapfile -t pending < <(${K} get csr -o jsonpath='{range .items[?(@.status == nil)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  for name in "${pending[@]:-}"; do
    # approve only kubelet-serving CSRs from our SA
    local signer req sa
    signer="$(${K} get csr "$name" -o jsonpath='{.spec.signerName}' 2>/dev/null || true)"
    req="$(${K} get csr "$name" -o jsonpath='{.spec.username}' 2>/dev/null || true)"
    if [[ "$signer" == "kubernetes.io/kubelet-serving" && "$req" == "system:serviceaccount:${NAMESPACE}:${NODE_NAME}" ]]; then
      echo "[INFO] Approving CSR $name"
      ${K} certificate approve "$name" || true
    fi
  done
}

### =======================
### Pre-flight
### =======================
need_cmd helm
KUBECTL="$(pick_kubectl)" || die "kubectl cannot reach the cluster; check kubeconfig or try with sudo."
echo "[INFO] Using KUBECTL='$KUBECTL'"

VALUES_FILE="$(mktemp -t interlink-values.XXXX.yaml)"
cat >"$VALUES_FILE" <<EOF
nodeName: ${NODE_NAME}
interlink:
  address: "http://${INTERLINK_HOST}"
  port: ${INTERLINK_PORT}
OAUTH:
  enabled: false
virtualNode:
  resources: { CPUs: ${CPUS}, memGiB: ${MEM_GIB}, pods: ${PODS} }
EOF
echo "[INFO] Wrote Helm values to: $VALUES_FILE"
echo "[INFO] Target interLink API: http://${INTERLINK_HOST}:${INTERLINK_PORT}"

### =======================
### Helm install/upgrade
### =======================
echo "[INFO] Installing/Upgrading Helm release '${NODE_NAME}' in namespace '${NAMESPACE}' ..."
helm upgrade --install -n "${NAMESPACE}" --create-namespace "${NODE_NAME}" "${CHART}" \
  --version "${CHART_VER}" --values "${VALUES_FILE}"

# Wait for the VK deployment (name is <release>-node)
echo "[INFO] Waiting for Deployment/${NODE_NAME}-node rollout ..."
${KUBECTL} -n "${NAMESPACE}" rollout status deploy/"${NODE_NAME}"-node --timeout=5m

### =======================
### Optional: avoid host kubelet port clash
### =======================
HOSTNET="$(${KUBECTL} -n "${NAMESPACE}" get deploy "${NODE_NAME}"-node -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "false")"
if [ "${HOSTNET}" = "true" ]; then
  echo "[INFO] hostNetwork=true detected; setting KUBELET_PORT=${KUBELET_PORT} to avoid 10250 clash ..."
  ${KUBECTL} -n "${NAMESPACE}" set env deploy/"${NODE_NAME}"-node KUBELET_PORT="${KUBELET_PORT}" --overwrite
  ${KUBECTL} -n "${NAMESPACE}" rollout status deploy/"${NODE_NAME}"-node --timeout=5m
fi

### =======================
### Minimal CSR RBAC (for kubectl logs/exec later)
### =======================
echo "[INFO] Applying minimal CSR RBAC for service account ${NAMESPACE}:${NODE_NAME} ..."
cat <<EOF | ${KUBECTL} apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vk-csr-create-${NODE_NAME}
rules:
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests"]
  verbs: ["create","get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vk-csr-create-${NODE_NAME}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vk-csr-create-${NODE_NAME}
subjects:
- kind: ServiceAccount
  name: ${NODE_NAME}
  namespace: ${NAMESPACE}
EOF

### =======================
### Node readiness & (optional) CSR auto-approvals
### =======================
echo "[INFO] Checking remote /pinglink ..."
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://${INTERLINK_HOST}:${INTERLINK_PORT}/pinglink" || true)"
echo "[INFO] Remote /pinglink HTTP status: ${HTTP_CODE}"

echo "[INFO] Waiting for Node/${NODE_NAME} to become Ready ..."
for i in $(seq 1 120); do
  READY="$(${KUBECTL} get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [ "${READY}" = "True" ]; then
    echo "[OK] Node ${NODE_NAME} is Ready."; break
  fi
  # opportunistic CSR approvals
  if [ "${AUTO_APPROVE_CSR}" = "true" ]; then approve_csrs "${KUBECTL}"; fi
  sleep 2
  if (( i % 15 == 0 )); then echo "[INFO] Still waiting... (${i}s)"; fi
done

READY="$(${KUBECTL} get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "${READY}" != "True" ]; then
  echo "[WARN] Node not Ready yet. Conditions:"
  ${KUBECTL} describe node "${NODE_NAME}" | sed -n '/Conditions:/,/Addresses:/p' || true
  echo "[HINT] Ensure http://${INTERLINK_HOST}:${INTERLINK_PORT}/pinglink returns 200 from cluster nodes."
fi

echo "[DONE] Helm install complete."
