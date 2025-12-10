import os
import json
import re
import shlex
from typing import Dict, List, Optional, Any
from datetime import datetime
from fastapi import HTTPException
import interlink
from .autolauncher_client import SSHClient, AutolauncherBackend

def _as_dict(x: Any) -> Dict[str, Any]:
    if x is None:
        return {}
    if isinstance(x, dict):
        return x
    for attr in ("dict", "model_dump"):
        fn = getattr(x, attr, None)
        if callable(fn):
            try:
                return fn()
            except:
                pass
    return {}

def parse_cpu(cpu: Optional[str]) -> int:
    if not cpu:
        return 0
    s = str(cpu).strip()
    if s.endswith("m"):
        try:
            return max(1, (int(re.sub("[^0-9]", "", s)) + 999)//1000)
        except:
            return 0
    try:
        return int(float(s))
    except:
        return 0

class AutolauncherProvider(interlink.provider.Provider):
    def __init__(self, cfg: dict):
        super().__init__()
        self.cfg = cfg or {}
        state_default = os.path.expanduser("~/.interlink/autolauncher-plugin-state.json")
        self.state_path = os.path.expanduser((self.cfg.get("plugin") or {}).get("state_path", state_default))
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
        self.backend = AutolauncherBackend(
            self.ssh,
            remote_base_dir=hpc.get("remote_base_dir", "/gpfs/projects/bsc70/INTERLINK/jobs"),
            autolauncher_path=hpc.get("autolauncher_path", "~/.autolauncher/autolauncher.py")
        )
        self.cluster = hpc.get("cluster", "amd")
        self.singularity_version = hpc.get("singularity_version", "3.6.4")
        self.extra_bindings = hpc.get("extra_bindings", [])
        self.image_map = hpc.get("image_map", {}) or {}

        local_auto = os.path.join(os.path.dirname(__file__), "hpc", "autolauncher.py")
        if os.path.exists(local_auto):
            try:
                self.backend.deploy_autolauncher_if_missing(local_auto)
            except:
                pass

    def create(self, pod: Any) -> None:
        def get_attr(obj, *keys, default=None):
            curr = obj
            for k in keys:
                if isinstance(curr, dict):
                    curr = curr.get(k)
                else:
                    curr = getattr(curr, k, None)
                if curr is None:
                    return default
            return curr

        if isinstance(pod, dict):
            meta = get_attr(pod, "pod", "metadata") or {}
            spec = get_attr(pod, "pod", "spec") or {}
            containers = spec.get("containers", [])
            c = containers[0] if containers else {}
            uid, name, ns = meta.get("uid"), meta.get("name"), meta.get("namespace")
            image = c.get("image")
            res_raw = c.get("resources")
            command = c.get("command", [])
            args = c.get("args", [])
        else:
            c = pod.pod.spec.containers[0]
            uid, name, ns = pod.pod.metadata.uid, pod.pod.metadata.name, pod.pod.metadata.namespace
            image = c.image
            res_raw = getattr(c, "resources", None)
            command = getattr(c, "command", [])
            args = getattr(c, "args", [])
        
        res = _as_dict(res_raw)
        limits = _as_dict(res.get("limits"))
        requests = _as_dict(res.get("requests"))
        cpu = limits.get("cpu") or requests.get("cpu")
        gpu = limits.get("nvidia.com/gpu") or limits.get("amd.com/gpu") or limits.get("gpu")
        
        hpc = self.cfg.get("hpc", {}) or {}
        gres = int(hpc.get("default_gres", 1))
        cpus_per_task = int(hpc.get("default_cpus_per_task", 4))
        if cpu:
            cpus_per_task = max(1, parse_cpu(str(cpu)))
        if gpu: 
            try:
                gres = max(1, int(float(str(gpu))))
            except:
                pass

        slurm = {"gres": gres, "cpus-per-task": cpus_per_task, "ntasks": 1, "qos": hpc.get("default_qos", "debug"), "time": hpc.get("default_time", "00:30:00")}

        # Logic: Quote args for shell safety, then escape quotes for remote wrapper
        full_list = (command or []) + (args or [])
        if not full_list:
             flat_cmd = "sleep 3600"
        else:
             # shlex.quote handles spaces/special chars within args (e.g. 'echo hello' becomes "'echo hello'")
             flat_cmd = " ".join(shlex.quote(str(x)) for x in full_list)
        
        # Escape double quotes because the remote script wraps this in "..."
        inner_cmd = flat_cmd.replace('\\', '\\\\').replace('"', '\\"')

        writable = False
        if image in self.image_map:
            containerdir, writable = self.image_map[image], True
        elif any(image.startswith(x) for x in ["docker://", "library://"]) or image.endswith(".sif"):
            containerdir = image
        else:
            containerdir = f"docker://{image}"

        workdir_remote, _, _ = self.backend.ensure_remote_layout(uid)
        clean_bindings = [b for b in self.extra_bindings if "hpai" not in b]

        params = {
            "cluster": self.cluster,
            "job_name": f"{name}-{uid[:8]}",
            "workdir": workdir_remote,
            "containerdir": containerdir,
            "singularity_version": self.singularity_version,
            "binary": "", # Empty binary to prevent double-shell nesting
            "command": inner_cmd,
            "args": "",
            "add_commit_tag": False,
            "use_code_in_gpfs": False,
            "qos": slurm["qos"],
            "time": slurm["time"],
            "ntasks": slurm["ntasks"],
            "cpus-per-task": slurm["cpus-per-task"],
            "gres": slurm["gres"],
            "bindings_list": clean_bindings,
            "writable": False,
        }

        remote_json = self.backend.stage_job_json(uid, params)
        ok, job_id, raw = self.backend.submit(remote_json, self.cluster)
        
        if not ok or not job_id:
            raise HTTPException(status_code=500, detail=f"Submission failed. Output: {raw}")

        self.state[uid] = {"job_id": job_id, "workdir": workdir_remote, "submitted_at": datetime.utcnow().isoformat(), "name": name, "namespace": ns}
        self._save_state()

    def delete(self, pod: Any) -> None:
        uid = getattr(pod.metadata, "uid", None) if hasattr(pod, "metadata") else pod.get("metadata", {}).get("uid")
        st = self.state.get(uid)
        if not st:
            raise HTTPException(status_code=404, detail="Unknown pod UID")
        self.backend.cancel(st["job_id"])
        self.state.pop(uid, None)
        self._save_state()

    def status(self, pod: Any) -> interlink.PodStatus:
        uid = getattr(pod.metadata, "uid", None) if hasattr(pod, "metadata") else pod.get("metadata", {}).get("uid")
        st = self.state.get(uid)
        name = (st or {}).get("name", "unknown")
        ns = (st or {}).get("namespace", "unknown")
        
        if not st:
            return interlink.PodStatus(name=name, UID=uid, namespace=ns, containers=[interlink.ContainerStatus(name="container", state=interlink.ContainerStates(terminated=interlink.StateTerminated(reason="Unknown", exitCode=1)))])

        try:
            state, _ = self.backend.squeue_state(st["job_id"])
        except:
            state = "Unknown"

        if state in ("RUNNING", "COMPLETING"):
            s = interlink.ContainerStates(running=interlink.StateRunning(started_at=datetime.utcnow().isoformat()))
        elif state in ("PENDING", "CONFIGURING", "RESIZING"):
            s = interlink.ContainerStates(waiting=interlink.StateWaiting(reason=state))
        else:
            s = interlink.ContainerStates(terminated=interlink.StateTerminated(reason=state, exitCode=0 if state == "COMPLETED" else 1))

        return interlink.PodStatus(name=name, UID=uid, namespace=ns, containers=[interlink.ContainerStatus(name="container", state=s)])

    def get_logs(self, req: interlink.LogRequest) -> bytes:
        st = self.state.get(req.pod_uid)
        if not st:
            raise HTTPException(status_code=404, detail="Unknown pod UID")
        log = self.backend.read_logs(st["workdir"], st["job_id"], tail=getattr(req.Opts, "Tail", None), timestamps=getattr(req.Opts, "Timestamps", False), stream="out")
        return (log or "").encode("utf-8")

    def _load_state(self) -> Dict[str, dict]:
        if os.path.exists(self.state_path):
            try:
                with open(self.state_path, "r") as f:
                    return json.load(f)
            except:
                pass
        return {}

    def _save_state(self) -> None:
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=2)
        os.replace(tmp, self.state_path)
