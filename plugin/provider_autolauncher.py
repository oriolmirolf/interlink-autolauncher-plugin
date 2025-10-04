\
import os
import json
import yaml
import re
from typing import Dict, List, Optional
from datetime import datetime

from fastapi import HTTPException
import interlink

from .autolauncher_client import SSHClient, AutolauncherBackend

def parse_cpu(cpu: Optional[str]) -> int:
    """
    Convert k8s CPU string to integer cores (ceil).
    E.g., '500m' -> 1, '2' -> 2
    """
    if not cpu:
        return 0
    s = str(cpu).strip()
    if s.endswith("m"):
        milli = int(re.sub("[^0-9]", "", s))
        return 1 if milli > 0 else 0 if milli == 0 else int((milli + 999)//1000)
    try:
        return int(float(s))
    except Exception:
        return 0

def parse_mem_to_mb(mem: Optional[str]) -> int:
    if not mem:
        return 0
    s = str(mem).strip().lower()
    try:
        if s.endswith("gi"):
            return int(float(s[:-2]) * 1024)
        if s.endswith("g"):
            return int(float(s[:-1]) * 1024)
        if s.endswith("mi"):
            return int(float(s[:-2]))
        if s.endswith("m"):
            return int(float(s[:-1]))
        if s.endswith("ki"):
            return max(1, int(float(s[:-2]) / 1024))
        if s.endswith("k"):
            return max(1, int(float(s[:-1]) / 1024))
        # bytes
        if s.endswith("b"):
            return max(1, int(float(s[:-1]) / (1024*1024)))
        # plain number assume Mi
        return int(float(s))
    except Exception:
        return 0

class AutoLauncherProvider(interlink.provider.Provider):
    """
    Provider that translates Pod requests into BSC Autolauncher submissions over SSH.
    """
    def __init__(self, cfg: dict):
        super().__init__()
        self.cfg = cfg
        self.state_path = os.path.expanduser(cfg.get("plugin", {}).get("state_path", "/var/lib/autolauncher-plugin/state.json"))
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        self.state = self._load_state()

        hpc = cfg.get("hpc", {})
        ssh_conf = cfg.get("ssh", {})
        self.ssh = SSHClient(
            user=hpc.get("user", ""),
            host=hpc.get("login_host", ""),
            extra_args=ssh_conf.get("extra_args", ""),
            key_path=ssh_conf.get("key_path")
        )
        self.backend = AutolauncherBackend(self.ssh, hpc.get("remote_base_dir", "/gpfs/projects/bsc70/INTERLINK/jobs"))
        self.cluster = hpc.get("cluster", "amd")
        self.singularity_version = hpc.get("singularity_version", "3.6.4")
        self.module_init = hpc.get("module_init", "module load rocm singularity")
        self.image_map = hpc.get("image_map", {})
        self.extra_bindings = hpc.get("extra_bindings", [])

    # ---------- persistence ----------
    def _load_state(self) -> Dict[str, dict]:
        if os.path.exists(self.state_path):
            try:
                with open(self.state_path, "r") as f:
                    return json.load(f)
            except Exception:
                return {}
        return {}

    def _save_state(self) -> None:
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=2)
        os.replace(tmp, self.state_path)

    # ---------- mapping helpers ----------
    def _container_cmd(self, container: interlink.Container) -> str:
        cmds = " ".join(container.command) if getattr(container, "command", None) else ""
        args = " ".join(container.args) if getattr(container, "args", None) else ""
        return (cmds + " " + args).strip() or "sleep 3600"

    def _image_to_sif(self, image: str) -> str:
        # Use mapping if present; fallback to image as-is
        return self.image_map.get(image, image)

    def _slurm_from_resources(self, resources: Optional[dict]) -> dict:
        hpc = self.cfg.get("hpc", {})
        gres = hpc.get("default_gres", 1)
        cpus_per_task = hpc.get("default_cpus_per_task", 4)
        ntasks = hpc.get("default_ntasks", 1)
        qos = hpc.get("default_qos", "debug")
        time_str = hpc.get("default_time", "00:30:00")

        if resources:
            limits = resources.get("limits") or {}
            requests = resources.get("requests") or {}
            cpu = limits.get("cpu") or requests.get("cpu")
            mem = limits.get("memory") or requests.get("memory")
            gpu = limits.get("nvidia.com/gpu") or limits.get("amd.com/gpu") or limits.get("gpu")

            if cpu:
                cpus_per_task = max(1, parse_cpu(str(cpu)))
            if gpu:
                try:
                    gres = max(1, int(float(str(gpu))))
                except Exception:
                    gres = hpc.get("default_gres", 1)
            # we could map memory to qos/partition, but Autolauncher profiles leave it to QOS/constraint

        return {
            "gres": gres,
            "cpus-per-task": cpus_per_task,
            "ntasks": ntasks,
            "qos": qos,
            "time": time_str
        }

    # ---------- Provider interface ----------
    def create(self, pod: interlink.Pod) -> None:
        """
        Prepare parameters JSON and submit the job via autolauncher on AMD-CTE.
        """
        # For simplicity, handle only first container
        container = pod.pod.spec.containers[0]
        workdir_remote, _, _ = self.backend.ensure_remote_layout(pod.pod.metadata.uid)

        # Build autolauncher params
        slurm = self._slurm_from_resources(container.resources.dict() if hasattr(container, "resources") and container.resources else None)

        # Prepare command to run inside the container (bash -lc "<cmd>")
        inner_cmd = self._container_cmd(container)
        binary = "/bin/bash -lc"  # will be wrapped by autolauncher with bash -c "<binary> <command>"
        sif = self._image_to_sif(container.image)

        params = {
            "cluster": self.cluster,
            "job_name": f"{pod.pod.metadata.name}-{pod.pod.metadata.uid[:8]}",
            "workdir": workdir_remote,
            "containerdir": sif,
            "singularity_version": self.singularity_version,
            "binary": binary,
            "command": inner_cmd,
            "args": "",
            "add_commit_tag": False,
            "use_code_in_gpfs": True,
            "qos": slurm["qos"],
            "time": slurm["time"],
            "ntasks": slurm["ntasks"],
            "cpus-per-task": slurm["cpus-per-task"],
            "gres": slurm["gres"],
            "bindings_list": self.extra_bindings,
        }

        # Stage JSON and submit
        remote_json = self.backend.stage_job_json(pod.pod.metadata.uid, params)
        ok, job_id, raw = self.backend.submit(remote_json, self.cluster)
        if not ok or not job_id:
            raise HTTPException(status_code=500, detail=f"Submission failed. Output: {raw}")

        # Save state
        self.state[pod.pod.metadata.uid] = {
            "job_id": job_id,
            "workdir": workdir_remote,
            "submitted_at": datetime.utcnow().isoformat(),
            "name": pod.pod.metadata.name,
            "namespace": pod.pod.metadata.namespace
        }
        self._save_state()

    def delete(self, pod: interlink.PodRequest) -> None:
        st = self.state.get(pod.metadata.uid)
        if not st:
            raise HTTPException(status_code=404, detail="Unknown pod UID")
        self.backend.cancel(st["job_id"])
        # Optional: cleanup files
        # self.ssh.run(f"rm -rf {st['workdir']}", check=False)
        self.state.pop(pod.metadata.uid, None)
        self._save_state()

    def status(self, pod: interlink.PodRequest) -> interlink.PodStatus:
        st = self.state.get(pod.metadata.uid)
        if not st:
            # If we don't know it, mark as terminated unknown
            return interlink.PodStatus(
                name=pod.metadata.name,
                UID=pod.metadata.uid,
                namespace=pod.metadata.namespace,
                containers=[
                    interlink.ContainerStatus(
                        name=pod.spec.containers[0].name if pod.spec and pod.spec.containers else "container",
                        state=interlink.ContainerStates(
                            running=None,
                            waiting=None,
                            terminated=interlink.StateTerminated(reason="Unknown", exitCode=1)
                        )
                    )
                ]
            )

        state, raw = self.backend.squeue_state(st["job_id"])
        # Map SLURM state to k8s-like
        if state in ("RUNNING", "COMPLETING"):
            return interlink.PodStatus(
                name=st["name"],
                UID=pod.metadata.uid,
                namespace=st["namespace"],
                containers=[interlink.ContainerStatus(
                    name=pod.spec.containers[0].name if pod.spec and pod.spec.containers else "container",
                    state=interlink.ContainerStates(
                        running=interlink.StateRunning(started_at=datetime.utcnow().isoformat()),
                        waiting=None,
                        terminated=None
                    )
                )]
            )
        elif state in ("PENDING", "CONFIGURING", "RESIZING"):
            return interlink.PodStatus(
                name=st["name"],
                UID=pod.metadata.uid,
                namespace=st["namespace"],
                containers=[interlink.ContainerStatus(
                    name=pod.spec.containers[0].name if pod.spec and pod.spec.containers else "container",
                    state=interlink.ContainerStates(
                        running=None,
                        waiting=interlink.StateWaiting(reason=state),
                        terminated=None
                    )
                )]
            )
        else:
            # COMPLETED, FAILED, CANCELLED, TIMEOUT etc -> terminated
            exit_code = 0 if state == "COMPLETED" else 1
            return interlink.PodStatus(
                name=st["name"],
                UID=pod.metadata.uid,
                namespace=st["namespace"],
                containers=[interlink.ContainerStatus(
                    name=pod.spec.containers[0].name if pod.spec and pod.spec.containers else "container",
                    state=interlink.ContainerStates(
                        running=None,
                        waiting=None,
                        terminated=interlink.StateTerminated(reason=state, exitCode=exit_code)
                    )
                )]
            )

    def Logs(self, req: interlink.LogRequest) -> bytes:
        st = self.state.get(req.pod_uid)
        if not st:
            raise HTTPException(status_code=404, detail="Unknown pod UID")
        log = self.backend.read_logs(st["workdir"], st["job_id"], tail=getattr(req.Opts, "Tail", None), timestamps=getattr(req.Opts, "Timestamps", False), stream="out")
        return log.encode("utf-8")

