#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-interlink}"                # namespace where your interLink node runs
DEPLOY="${DEPLOY:-}"                 # deployment name, e.g. my-vk-node-node
SOCKET_HOST_PATH="${SOCKET_HOST_PATH:-/var/run/interlink}"
SOCKET_FILE="${SOCKET_FILE:-.plugin.sock}"
ENDPOINT="unix://${SOCKET_HOST_PATH}/${SOCKET_FILE}"
MOUNT_NAME="interlink-plugin-sock"

usage() { echo "Usage: NS=<namespace> DEPLOY=<deploy-name> $0"; }

if [[ -z "${DEPLOY}" ]]; then
  echo "[!] DEPLOY not set. Try auto-detecting in namespace '${NS}'..."
  DEPLOY="$(kubectl -n "${NS}" get deploy -o name | grep -E 'node$|vk|interlink' | head -n1 | sed 's#.*/##' || true)"
fi
[[ -n "${DEPLOY}" ]] || { echo "Could not auto-detect the InterLink node Deployment."; usage; exit 1; }

echo "[i] Patching deployment ${NS}/${DEPLOY}"
echo "    - HostPath mount: ${SOCKET_HOST_PATH}"
echo "    - Socket file   : ${SOCKET_FILE}"
echo "    - Plugin endpoint: ${ENDPOINT}"

# 1) Add hostPath volume + mount so the pod sees /var/run/interlink/.plugin.sock
kubectl -n "${NS}" patch deploy "${DEPLOY}" --type='json' -p "
[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes/-\",\"value\":{
      \"name\":\"${MOUNT_NAME}\",
      \"hostPath\":{\"path\":\"${SOCKET_HOST_PATH}\",\"type\":\"DirectoryOrCreate\"}
  }}
]
" || true

# 2) Mount the volume into the first container (assumed to be the node)
kubectl -n "${NS}" patch deploy "${DEPLOY}" --type='json' -p "
[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/-\",\"value\":{
      \"name\":\"${MOUNT_NAME}\",\"mountPath\":\"${SOCKET_HOST_PATH}\"
  }}
]
" || true

# 3) Set commonly-used env names (different interLink builds read either one)
for VAR in SIDECAR_ENDPOINT PLUGIN_ENDPOINT INTERLINK_PLUGIN_ENDPOINT; do
  kubectl -n "${NS}" set env deploy/"${DEPLOY}" ${VAR}="${ENDPOINT}" >/dev/null
done

echo "[i] Restarting pods to pick up changes..."
kubectl -n "${NS}" rollout restart deploy "${DEPLOY}"
kubectl -n "${NS}" rollout status deploy "${DEPLOY}" --timeout=120s

echo "[i] Done. Verify logs mention the endpoint (${ENDPOINT}):"
echo "    kubectl -n ${NS} logs deploy/${DEPLOY} --all-containers | grep -i endpoint || true"
