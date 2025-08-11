import os, json, time
from typing import List
from plugin_state import PluginState
from autolauncher import LocalRunner, HPCRunner
from utils import gen_podjid

class AutolauncherAdapter:
    """
    Bridges InterLink plugin API to Autolauncher actions.
    Supports:
      - local mode (docker)
      - hpc mode (ssh+slurm) -> stub hooks provided
    Mode can be forced by env: PLUGIN_MODE=local|hpc
    """
    def __init__(self, state: PluginState):
        self.state = state
        self.mode_env = os.getenv("PLUGIN_MODE", "").lower().strip()

    def _mode_for(self, annotations: dict | None) -> str:
        ann = annotations or {}
        explicit = (ann.get("interlink.autolauncher/mode") or "").lower()
        mode = explicit or self.mode_env or "local"
        if mode not in ("local","hpc"):
            mode = "local"
        return mode

    def _target_for(self, annotations: dict | None) -> str:
        ann = annotations or {}
        target = (ann.get("interlink.autolauncher/target") or "").lower() or "local"
        return target

    # ---------- /create ----------
    def create(self, pods: List) -> List[dict]:
        results = []
        for p in pods:
            pod         = p.pod
            meta        = pod.metadata
            spec        = pod.spec
            uid         = meta.uid or meta.name or gen_podjid()[:12]
            namespace   = meta.namespace or "default"
            annotations = meta.annotations or {}
            mode        = self._mode_for(annotations)
            target      = self._target_for(annotations)

            container   = spec.containers[0]
            image       = container.image
            command     = container.command or []
            args        = container.args or []

            # already created?
            if self.state.exists(uid):
                info = self.state.get(uid)
                results.append({"PodUID": uid, "PodJID": info.get("jid","")})
                continue

            # dispatch by mode
            if mode == "local":
                runner = LocalRunner()
                jid = runner.launch(
                    uid=uid,
                    namespace=namespace,
                    image=image,
                    command=command,
                    args=args,
                )
                started_at = time.time()
                self.state.upsert(uid, {
                    "name"          : meta.name or uid,
                    "namespace"     : namespace,
                    "mode"          : "local",
                    "target"        : target,
                    "image"         : image,
                    "jid"           : jid,
                    "created_at"    : started_at,
                    "status"        : "Running",
                    "container_name": container.name,
                    "log_cursor"    : 0,
                })
            else:
                runner = HPCRunner(target=target)
                jid = runner.launch_hpc(uid=uid, namespace=namespace, image=image, command=command, args=args)
                self.state.upsert(uid, {
                    "name"          : meta.name or uid,
                    "namespace"     : namespace,
                    "mode"          : "hpc",
                    "target"        : target,
                    "image"         : image,
                    "jid"           : jid,
                    "created_at"    : time.time(),
                    "status"        : "Pending",
                    "container_name": container.name,
                    "log_cursor"    : 0,
                })

            results.append({"PodUID": uid, "PodJID": jid})
        return results

    # ---------- /status ----------
    def status(self, pods: List) -> List[dict]:
        out = []
        for pod in pods:
            meta = pod.metadata
            spec = pod.spec
            uid = meta.uid or ""
            namespace = meta.namespace or "default"
            info = self.state.get(uid) if uid else None

            if not info:
                # ...?
                raise RuntimeError("No container found for UID")

            if info["mode"] == "local":
                runner = LocalRunner()
                s = runner.status(info["jid"])
            else:
                runner = HPCRunner(target=info.get("target","local"))
                s = runner.status_hpc(info["jid"])

            # map to InterLink schema
            if s["phase"] == "Running":
                cs = {
                    "name": info["container_name"],
                    "state": {"terminated": None, "waiting": None,
                              "running": {"startedAt": s.get("startedAt")}}
                }
            elif s["phase"] == "Succeeded":
                cs = {
                    "name": info["container_name"],
                    "state": {"running": None, "waiting": None,
                              "terminated": {"exitCode": 0, "reason": "Completed"}}
                }
            else:
                cs = {
                    "name": info["container_name"],
                    "state": {"running": None, "terminated": None,
                              "waiting": {"reason": s.get("reason","Pending"), "message": None}}
                }

            out.append({
                "name": info["name"],
                "UID": uid,
                "JID": info.get("jid"),
                "namespace": namespace,
                "containers": [cs],
            })
        return out

    # ---------- /getLogs ----------
    def get_logs(self, req) -> str:
        info = self.state.get(req.PodUID)
        if not info:
            raise RuntimeError("No container recorded for this pod")

        if info["mode"] == "local":
            runner = LocalRunner()
            logs = runner.logs(info["jid"], tail=req.Opts.Tail, previous=req.Opts.Previous, timestamps=req.Opts.Timestamps)
        else:
            runner = HPCRunner(target=info.get("target","local"))
            logs = runner.logs_hpc(info["jid"], tail=req.Opts.Tail)

        return logs

    # ---------- /delete ----------
    def delete(self, pod):
        meta = pod.metadata
        uid = meta.uid or ""
        info = self.state.get(uid)
        if not info:
            return

        if info["mode"] == "local":
            LocalRunner().delete(info["jid"])
        else:
            HPCRunner(target=info.get("target","local")).delete_hpc(info["jid"])

        self.state.remove(uid)
