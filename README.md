# interlink-autolauncher-plugin

This plugin lets interLink offload a pod into **SLURM via your `autolauncher.py`**. It builds the JSON config, calls the launcher, tracks the SLURM JobID, and exposes `/status`, `/delete`, and `/getLogs`.

## Features
- Works with MN4/AMD/P9 launchers defined in your script
- Optional SSH mode (edge-node → SLURM master)
- Deterministic output/error filenames → easy log streaming
- Maps basic Pod resources/annotations → Autolauncher params

## Quick start (dev)

```bash
pip install -r requirements.txt
export IL_AUTOLAUNCHER_PATH=/gpfs/projects/bsc70/hpai/vendor/autolauncher/autolauncher.py
uvicorn main:app --reload --host 0.0.0.0 --port 8000
````

## Environment

* `IL_AUTOLAUNCHER_PATH` — absolute path to `autolauncher.py` on the target host.
* `IL_SSH_DEST` — `user@host` (optional). If set, plugin will `ssh`/`scp` to run remotely.
* `IL_DEFAULT_*` — sensible defaults for cluster/workdir/containerdir/etc.

## Pod → Autolauncher mapping

Set **annotations** on the Kubernetes Pod to control Autolauncher:

| Annotation key                              | Meaning                                              |
| ------------------------------------------- | ---------------------------------------------------- |
| `autolauncher.interlink/cluster`            | `mn4` \| `amd` \| `p9` \| `local`                    |
| `autolauncher.interlink/workdir`            | GPFS work dir for the job                            |
| `autolauncher.interlink/containerdir`       | Singularity sandbox dir (or Docker image in `local`) |
| `autolauncher.interlink/singularityVersion` | e.g., `3.6.4`                                        |
| `autolauncher.interlink/binary`             | e.g., `python`                                       |
| `autolauncher.interlink/command`            | Script relative to workdir (if `useCodeInGPFS=true`) |
| `autolauncher.interlink/args`               | Arguments string                                     |
| `autolauncher.interlink/useCodeInGPFS`      | `true`/`false`                                       |
| `autolauncher.interlink/addCommitTag`       | `true`/`false`                                       |
| `autolauncher.interlink/qos`                | SLURM QOS                                            |
| `autolauncher.interlink/walltime`           | SLURM time `HH:MM:SS`                                |
| `autolauncher.interlink/ntasks`             | Integer                                              |
| `autolauncher.interlink/cpusPerTask`        | Integer                                              |
| `autolauncher.interlink/gres`               | GPUs number (e.g., `1`)                              |
| `autolauncher.interlink/highmem`            | `true`/`false`                                       |
| `autolauncher.interlink/binds`              | Comma-separated `src:dst` list for extra binds       |

The container `resources.limits` may also map CPU/GPU to `cpus-per-task` and `gres`.

## Example Create payload (abridged)

```json
[
  {
    "pod": {
      "metadata": {
        "name": "hpai-train",
        "namespace": "default",
        "uid": "123e4567-e89b-12d3-a456-426614174000",
        "annotations": {
          "autolauncher.interlink/cluster": "amd",
          "autolauncher.interlink/workdir": "/gpfs/projects/bsc70/hpai/work/exp1",
          "autolauncher.interlink/containerdir": "/gpfs/projects/bsc70/hpai/containers/rocm-sif-sandbox",
          "autolauncher.interlink/command": "src/train.py",
          "autolauncher.interlink/args": "--epochs 5 --batch 64",
          "autolauncher.interlink/qos": "debug",
          "autolauncher.interlink/walltime": "01:00:00",
          "autolauncher.interlink/gres": "1",
          "autolauncher.interlink/cpusPerTask": "8"
        }
      },
      "spec": {
        "containers": [
          {
            "name": "trainer",
            "image": "ignored-by-autolauncher",
            "command": ["python", "src/train.py"],
            "args": ["--epochs", "5"]
          }
        ]
      }
    },
    "configmaps": [],
    "secrets": [],
    "projectedvolumesmaps": []
  }
]
```

## Status mapping

* `squeue` → `RUNNING` or `PENDING` (mapped to interLink Running/Waiting)
* `sacct` → `COMPLETED`/`FAILED`/`CANCELLED`/`TIMEOUT` (mapped to Terminated with exitCode)

## Logs

The plugin sets deterministic filenames (under `${workdir}/output/`) and streams either `*_out.txt` or `*_err.txt`. To get stderr, pass container name ending with `:stderr` to `/getLogs`.

## Delete

Calls `scancel <JID>` if a JobID is known. If already gone, returns success.

## Notes & TODOs

* Environment variables & Secrets: current version leaves them to Autolauncher defaults (MINIO, etc.). If you want arbitrary env injection, extend Autolauncher to accept `env:` and prepend `export` lines in the generated script.
* Local (Docker) mode: supported through Autolauncher `local` cluster, but container naming is not deterministic; deletion is best-effort via SLURM only.
* Persistence: state JSON under `/var/lib/interlink-autolauncher/state.json` (or your mount).