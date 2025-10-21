import os
import json
import re
from typing import Dict, List, Optional, Any
from datetime import datetime
from fastapi import HTTPException
import interlink

from .autolauncher_client import SSHClient, AutolauncherBackend

def _as_dict(x: Any) -> Dict[str, Any]:
    # Works with pydantic v1 or v2 or plain dict
    if x is None:
        return {}
    if isinstance(x, dict):
        return x
    for attr in ("dict", "model_dump"):
        fn = getattr(x, attr, None)
        if callable(fn):
            try:
                return fn()
            except Exception:
                pass
    return {}

def parse_cpu(cpu: Optional[str]) -> int:
    if not cpu:
        return 0
    s = str(cpu).strip()
    if s.endswith("m"):
        try:
            v = int(re.sub("[^0-9]", "", s))
            return max(1, (v + 999)//1000)
        except Exception:
            return 0
    try:
        return int(float(s))
    except Exception:
        return 0

class AutolauncherProvider(interlink.provider.Provider):
    """
    InterLink provider that translates Pod create/status/delete/getLogs to BSC Autolauncher over SSH.
    """
    def __init__(self, cfg: dict):
        super().__init__()
        self.cfg = cfg or {}
        # store state in user home (writable by service user)
        state_default = os.path.expanduser("~/.interlink/autolauncher-plugin-state.json")
        self.state_path = os.path.expanduser(
            (self.cfg.get("plugin") or {}).get("state_path", state_default)
        )
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        self.state = self._load_state()

        hpc = self.cfg.get("hpc", {}) or {}
        ssh_conf = self.cfg.get("ssh", {}) or {}

        self.ssh = SSHClient(
            user=hpc.get("user", ""),
            host=hpc.get("login_host", "amdlogin1.bsc.es"),
            extra_args=ssh_conf.get("extra_args", "-o StrictHostKeyChecking=accept-new"),
            key_path=ssh_conf.get("key_path")
        )
        remote_root = hpc.get("remote_base_dir", "/gpfs/projects/bsc70/INTERLINK/jobs")
        self.backend = AutolauncherBackend(
            self.ssh,
            remote_base_dir=remote_root,
            autolauncher_path=hpc.get("autolauncher_path", "~/.autolauncher/autolauncher.py")
        )
        self.cluster = hpc.get("cluster", "amd")
        self.singularity_version = hpc.get("singularity_version", "3.6.4")
        self.module_init = hpc.get("module_init", "module load rocm singularity")
        self.image_map = hpc.get("image_map", {}) or {}
        self.extra_bindings = hpc.get("extra_bindings", [])

        # Optionally stage a patched autolauncher on first start
        local_auto = os.path.join(os.path.dirname(__file__), "hpc", "autolauncher.py")
        if os.path.exists(local_auto):
            try:
                self.backend.deploy_autolauncher_if_missing(local_auto)
            except Exception:
                pass

    # ---------- helpers ----------
    def _slurm_from_resources(self, resources: Optional[dict]) -> dict:
        hpc = self.cfg.get("hpc", {}) or {}
        gres = int(hpc.get("default_gres", 1))
        cpus_per_task = int(hpc.get("default_cpus_per_task", 4))
        ntasks = int(hpc.get("default_ntasks", 1))
        qos = hpc.get("default_qos", "debug")
        time_str = hpc.get("default_time", "00:30:00")

        if resources:
            limits = _as_dict(resources.get("limits"))
            requests = _as_dict(resources.get("requests"))
            cpu = (limits or {}).get("cpu") or (requests or {}).get("cpu")
            gpu = (limits or {}).get("nvidia.com/gpu") or (limits or {}).get("amd.com/gpu") or (limits or {}).get("gpu")
            if cpu:
                cpus_per_task = max(1, parse_cpu(str(cpu)))
            if gpu:
                try:
                    gres = max(1, int(float(str(gpu))))
                except Exception:
                    pass

        return {"gres": gres, "cpus-per-task": cpus_per_task, "ntasks": ntasks, "qos": qos, "time": time_str}

    def _container_cmd(self, container: interlink.Container) -> str:
        cmds = " ".join(getattr(container, "command", []) or [])
        args = " ".join(getattr(container, "args", []) or [])
        return (cmds + " " + args).strip() or "sleep 3600"

    def _resolve_image(self, image: str) -> (str, bool):
        """
        Returns (containerdir_or_uri, writable_flag). If an explicit mapping exists, assume it's a sandbox (writable).
        Else use docker:// URI and run read-only (writable=False).
        """
        if image in self.image_map:
            return self.image_map[image], True
        if image.startswith("docker://") or image.startswith("library://") or image.endswith(".sif"):
            return image, False
        return f"docker://{image}", False

    # ---------- Provider interface ----------
    def create(self, pod: interlink.Pod) -> None:
        c = pod.pod.spec.containers[0]
        res = _as_dict(getattr(c, "resources", None))
        slurm = self._slurm_from_resources(res)
        inner_cmd = self._container_cmd(c)
        containerdir, writable = self._resolve_image(c.image)

        # Prepare a remote workdir
        workdir_remote, _, _ = self.backend.ensure_remote_layout(pod.pod.metadata.uid)

        params = {
            "cluster": self.cluster,
            "job_name": f"{pod.pod.metadata.name}-{pod.pod.metadata.uid[:8]}",
            "workdir": workdir_remote,
            "containerdir": containerdir,
            "singularity_version": self.singularity_version,
            "binary": "/bin/bash -lc",
            "command": inner_cmd,
            "args": "",
            "add_commit_tag": False,
            "use_code_in_gpfs": False,
            "qos": slurm["qos"],
            "time": slurm["time"],
            "ntasks": slurm["ntasks"],
            "cpus-per-task": slurm["cpus-per-task"],
            "gres": slurm["gres"],
            "bindings_list": self.extra_bindings,
            "writable": bool(writable),
        }

        remote_json = self.backend.stage_job_json(pod.pod.metadata.uid, params)
        ok, job_id, raw = self.backend.submit(remote_json, self.cluster)
        if not ok or not job_id:
            raise HTTPException(status_code=500, detail=f"Submission failed. Output: {raw}")

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
        self.state.pop(pod.metadata.uid, None)
        self._save_state()

    def status(self, pod: interlink.PodRequest) -> interlink.PodStatus:
        st = self.state.get(pod.metadata.uid)
        name = (st or {}).get("name", pod.metadata.name)
        ns = (st or {}).get("namespace", pod.metadata.namespace)

        if not st:
            return interlink.PodStatus(
                name=name, UID=pod.metadata.uid, namespace=ns,
                containers=[interlink.ContainerStatus(
                    name=(pod.spec.containers[0].name if pod.spec and pod.spec.containers else "container"),
                    state=interlink.ContainerStates(
                        running=None, waiting=None,
                        terminated=interlink.StateTerminated(reason="Unknown", exitCode=1)
                    ))]
            )

        try:
            state, _ = self.backend.squeue_state(st["job_id"])
        except Exception:
            state = "Unknown"

        if state in ("RUNNING", "COMPLETING"):
            s = interlink.ContainerStates(running=interlink.StateRunning(started_at=datetime.utcnow().isoformat()),
                                          waiting=None, terminated=None)
        elif state in ("PENDING", "CONFIGURING", "RESIZING"):
            s = interlink.ContainerStates(running=None, waiting=interlink.StateWaiting(reason=state), terminated=None)
        else:
            exit_code = 0 if state == "COMPLETED" else 1
            s = interlink.ContainerStates(running=None, waiting=None,
                                          terminated=interlink.StateTerminated(reason=state, exitCode=exit_code))

        return interlink.PodStatus(
            name=name, UID=pod.metadata.uid, namespace=ns,
            containers=[interlink.ContainerStatus(
                name=(pod.spec.containers[0].name if pod.spec and pod.spec.containers else "container"),
                state=s
            )]
        )

    def get_logs(self, req: interlink.LogRequest) -> bytes:
        st = self.state.get(req.pod_uid)
        if not st:
            raise HTTPException(status_code=404, detail="Unknown pod UID")
        log = self.backend.read_logs(st["workdir"], st["job_id"],
                                     tail=getattr(req.Opts, "Tail", None),
                                     timestamps=getattr(req.Opts, "Timestamps", False),
                                     stream="out")
        return (log or "").encode("utf-8")

    # ---------- state I/O ----------
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
