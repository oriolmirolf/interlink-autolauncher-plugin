#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Config (override via env or flags)
# =========================
NS="${NS:-interlink}"
NODE="${NODE:-slurm-edge}"
JOB="${JOB:-slurm-iris-fast}"
WORK_PATH="${WORK_PATH:-/home/ubuntu/.interlink/work}"
IMAGE="${IMAGE:-python:3.11-slim}"
REQ_CPU="${REQ_CPU:-500m}"
REQ_MEM="${REQ_MEM:-512Mi}"
LIM_CPU="${LIM_CPU:-1}"
LIM_MEM="${LIM_MEM:-1Gi}"
TIMEOUT="${TIMEOUT:-600s}"     # wait timeout for job completion
CLEANUP="${CLEANUP:-false}"    # --cleanup to delete at the end

usage() {
  cat <<EOF
Usage: $(basename "$0") [--namespace NAMESPACE] [--node NODE] [--work-path PATH]
                         [--image IMG] [--timeout DUR] [--cleanup]
Env overrides:
  NS, NODE, JOB, WORK_PATH, IMAGE, REQ_CPU, REQ_MEM, LIM_CPU, LIM_MEM, TIMEOUT
Examples:
  NS=interlink NODE=slurm-edge ./$(basename "$0")
  ./$(basename "$0") --cleanup
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2;;
    --node) NODE="$2"; shift 2;;
    --work-path) WORK_PATH="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --cleanup) CLEANUP=true; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need kubectl
need sed
need awk

echo "[INFO] Namespace:   $NS"
echo "[INFO] Node:        $NODE"
echo "[INFO] Job name:    $JOB"
echo "[INFO] Work path:   $WORK_PATH"
echo "[INFO] Image:       $IMAGE"
echo "[INFO] Timeout:     $TIMEOUT"
echo "[INFO] Cleanup:     $CLEANUP"

# Create namespace if missing (no error if exists)
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

# Apply Job manifest (templated)
TMP_YAML="$(mktemp -t iris-job.XXXX.yaml)"
cat >"$TMP_YAML" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${NODE}
      tolerations:
        - key: virtual-node.interlink/no-schedule
          operator: Exists
      restartPolicy: Never
      containers:
        - name: trainer
          image: ${IMAGE}
          volumeMounts:
            - name: work
              mountPath: /work
          env:
            - name: HOME
              value: /work
            - name: TMPDIR
              value: /work/tmp
            - name: PIP_CACHE_DIR
              value: /work/pip
          command: ["sh","-lc"]
          args:
            - |
              set -ex
              PKGDIR="/work/pkgs-iris"; mkdir -p "\$PKGDIR" /work/tmp /work/pip
              python -m pip install --no-cache-dir -t "\$PKGDIR" \\
                numpy==2.0.1 scipy==1.16.1 scikit-learn==1.5.1
              export PYTHONPATH="\${PKGDIR}:\${PYTHONPATH:-}"
              python - <<'PY'
              from sklearn.datasets import load_iris
              from sklearn.model_selection import train_test_split
              from sklearn.preprocessing import StandardScaler
              from sklearn.linear_model import LogisticRegression
              from sklearn.pipeline import make_pipeline
              from sklearn.metrics import accuracy_score
              X,y = load_iris(return_X_y=True)
              Xtr,Xte,ytr,yte = train_test_split(X,y,test_size=0.2,random_state=42,stratify=y)
              model = make_pipeline(StandardScaler(), LogisticRegression(max_iter=500))
              model.fit(Xtr,ytr)
              print("iris_test_accuracy=", round(accuracy_score(yte, model.predict(Xte)),3))
              PY
          resources:
            requests:
              cpu: "${REQ_CPU}"
              memory: "${REQ_MEM}"
            limits:
              cpu: "${LIM_CPU}"
              memory: "${LIM_MEM}"
      volumes:
        - name: work
          hostPath:
            path: ${WORK_PATH}
            type: DirectoryOrCreate
EOF

echo "[INFO] Applying Job…"
kubectl apply -f "$TMP_YAML"

# Wait for completion (or failure)
echo "[INFO] Waiting for Job/${JOB} to complete (timeout ${TIMEOUT})…"
set +e
kubectl -n "$NS" wait --for=condition=complete "job/${JOB}" --timeout="$TIMEOUT"
WAIT_RC=$?
set -e

# Grab pod name
POD="$(kubectl -n "$NS" get pods -l job-name="${JOB}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${POD}" ]]; then
  echo "[ERROR] Could not find pod for Job/${JOB}"
  echo "[DIAG] Recent events:"
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 50 || true
  exit 1
fi
echo "[INFO] Pod: $POD"

# Logs (may require CSR approval in some clusters)
echo "[INFO] ----- Pod logs begin -----"
if ! kubectl -n "$NS" logs "$POD" 2>/tmp/_iris_logs_err.txt; then
  echo "[WARN] kubectl logs failed. Possible CSR approval required."
  echo "------ kubectl logs error ------"
  cat /tmp/_iris_logs_err.txt
  echo "------ Pending CSRs (if any) ---"
  kubectl get csr || true
  echo "Run: kubectl certificate approve <csr-name>   # then re-run logs."
else
  echo "[INFO] ----- Pod logs end -------"
  ACC_LINE="$(kubectl -n "$NS" logs "$POD" | grep -Eo 'iris_test_accuracy=\s*[0-9.]+')"
  if [[ -n "${ACC_LINE}" ]]; then
    echo "[OK] ${ACC_LINE}"
  else
    echo "[WARN] Accuracy line not found in logs."
  fi
fi

# If wait failed, dump diagnostics
if [[ $WAIT_RC -ne 0 ]]; then
  echo "[ERROR] Job did not complete within ${TIMEOUT}."
  echo "------ Pod describe -------------"
  kubectl -n "$NS" describe pod "$POD" || true
  echo "------ Recent events -------------"
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 50 || true
  exit 1
fi

# Optional cleanup
if [[ "$CLEANUP" == "true" ]]; then
  echo "[INFO] Cleaning up Job/${JOB}…"
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found=true
fi

echo "[DONE] Iris test job path: $WORK_PATH (hostPath on the edge node)"
