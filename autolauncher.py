import os, subprocess, json, time, shlex
from utils import run, now_rfc3339

class LocalRunner:
    """
    Local docker execution for smoke tests:
      - docker run -d --name <jid> <image> <command...>
      - status via docker inspect
      - logs via docker logs
    Requires: docker socket/daemon accessible.
    """

    def _ensure_name(self, uid: str) -> str:
        return f"auto-{uid[:24].lower()}"

    def launch(self, uid: str, namespace: str, image: str, command: list[str], args: list[str]) -> str:
        name = self._ensure_name(uid)
        cmd = ["docker","run","-d","--name",name, image]
        if command:
            cmd.extend(command)
        if args:
            cmd.extend(args)
        r = run(cmd, check=True)
        jid = r.stdout.strip() or name
        return jid

    def status(self, jid: str) -> dict:
        r = run(["docker","inspect",jid,"--format","{{json .State}}"], check=False)
        if r.returncode != 0:
            return {"phase":"Failed","reason":"NotFound"}
        st = json.loads(r.stdout.strip())
        if st.get("Running"):
            # StartedAt may be empty for very fresh containers; guard it
            started = st.get("StartedAt") or now_rfc3339()
            return {"phase":"Running","startedAt": started}
        if st.get("Status") == "exited" and int(st.get("ExitCode",1)) == 0:
            return {"phase":"Succeeded"}
        return {"phase":"Failed","reason": st.get("Error") or st.get("Status","Unknown")}

    def logs(self, jid: str, tail: int | None, previous: bool, timestamps: bool | None) -> str:
        cmd = ["docker","logs"]
        if tail is not None:
            cmd += ["--tail", str(tail)]
        if timestamps:
            cmd += ["--timestamps"]
        # docker has --since/--until etc; keep simple
        cmd += [jid]
        r = run(cmd, check=False)
        return r.stdout

    def delete(self, jid: str):
        run(["docker","rm","-f",jid], check=False)


class HPCRunner:
    """
    HPC (SSH + SLURM) runner — skeleton hooks.
    Fill with your site's SSH/rsync/sbatch tooling or bind to Autolauncher script.
    """

    def __init__(self, target: str = "mn5"):
        self.target = target

    def launch_hpc(self, uid: str, namespace: str, image: str, command: list[str], args: list[str]) -> str:
        # TODO: render launcher via your Autolauncher and call sbatch; return SLURM JobId (str)
        # For now, stub a synthetic id so API contract is satisfied.
        return f"slurm-{uid[:8]}"

    def status_hpc(self, jid: str) -> dict:
        # TODO: query squeue/sacct via SSH
        return {"phase":"Running","startedAt": now_rfc3339()}

    def logs_hpc(self, jid: str, tail: int | None) -> str:
        # TODO: tail slurm_output/out.txt via SSH
        return "HPC logs not yet implemented.\n"

    def delete_hpc(self, jid: str):
        # TODO: scancel via SSH
        pass
