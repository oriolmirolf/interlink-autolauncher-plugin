\
import os
import subprocess
import shlex
import json
import re
from typing import Optional, Tuple

class SSHClient:
    def __init__(self, user: str, host: str, extra_args: str = "", key_path: Optional[str] = None):
        self.user = user
        self.host = host
        self.extra_args = extra_args or ""
        self.key_path = os.path.expanduser(key_path) if key_path else None

    def _ssh_base(self) -> list[str]:
        cmd = ["ssh"]
        if self.key_path:
            cmd += ["-i", self.key_path]
        if self.extra_args:
            cmd += shlex.split(self.extra_args)
        cmd.append(f"{self.user}@{self.host}")
        return cmd

    def run(self, remote_cmd: str, check: bool = True, capture_output: bool = True, text: bool = True) -> subprocess.CompletedProcess:
        cmd = self._ssh_base() + [remote_cmd]
        return subprocess.run(cmd, check=check, capture_output=capture_output, text=text)

    def scp_put(self, local_path: str, remote_path: str) -> None:
        cmd = ["scp"]
        if self.key_path:
            cmd += ["-i", self.key_path]
        if self.extra_args:
            cmd += shlex.split(self.extra_args)
        cmd += [local_path, f"{self.user}@{self.host}:{remote_path}"]
        subprocess.run(cmd, check=True)

class AutolauncherBackend:
    """
    Thin wrapper to stage job JSON and call autolauncher.py on the remote AMD-CTE login node.
    """
    def __init__(self, ssh: SSHClient, remote_base_dir: str, autolauncher_path: str = "~/.autolauncher/autolauncher.py"):
        self.ssh = ssh
        self.remote_base_dir = remote_base_dir.rstrip("/")
        self.autolauncher_path = autolauncher_path

    def ensure_remote_layout(self, pod_uid: str) -> Tuple[str, str, str]:
        workdir = f"{self.remote_base_dir}/{pod_uid}"
        outdir = f"{workdir}/output"
        launchers = f"{workdir}/launchers"
        self.ssh.run(f"mkdir -p {shlex.quote(outdir)} {shlex.quote(launchers)}")
        return workdir, outdir, launchers

    def deploy_autolauncher_if_missing(self, local_autolauncher_py: str) -> None:
        # ensure remote directory
        self.ssh.run("mkdir -p ~/.autolauncher")
        # copy only if missing or different
        self.ssh.run("test -f ~/.autolauncher/autolauncher.py || echo missing", check=False)
        self.ssh.scp_put(local_autolauncher_py, "~/.autolauncher/autolauncher.py")

    def stage_job_json(self, pod_uid: str, params: dict) -> str:
        workdir, _, _ = self.ensure_remote_layout(pod_uid)
        remote_json = f"{workdir}/job.json"
        # Write to a temp file locally
        import tempfile, json, os
        fd, tmp = tempfile.mkstemp(prefix="job_", suffix=".json")
        with os.fdopen(fd, "w") as f:
            json.dump(params, f, indent=2)
        # Copy up and remove temp
        self.ssh.scp_put(tmp, remote_json)
        os.remove(tmp)
        return remote_json

    def submit(self, remote_json: str, cluster: str) -> Tuple[bool, Optional[str], str]:
        """
        Run autolauncher to submit the job; return (ok, jobid, raw_output)
        """
        cmd = f"python3 {self.autolauncher_path} -f {shlex.quote(remote_json)} --cluster {shlex.quote(cluster)}"
        proc = self.ssh.run(cmd, check=False)
        out = (proc.stdout or "") + (proc.stderr or "")
        # Parse SLURM job id from "Submitted batch job 12345"
        m = re.search(r"Submitted batch job\s+(\d+)", out)
        if m:
            return True, m.group(1), out
        # On 'local' cluster, there is no sbatch; try to extract a PID or fallback
        m2 = re.search(r"Launcher path: .*", out)
        return False, None, out

    def cancel(self, job_id: str) -> str:
        proc = self.ssh.run(f"scancel {shlex.quote(job_id)}", check=False)
        return (proc.stdout or "") + (proc.stderr or "")

    def squeue_state(self, job_id: str) -> Tuple[str, Optional[str]]:
        """
        Returns (state, raw) using squeue. If not found, try sacct.
        """
        # squeue first (running/pending)
        proc = self.ssh.run(f"squeue -h -j {shlex.quote(job_id)} -o %T", check=False)
        state = (proc.stdout or "").strip()
        raw = (proc.stdout or "") + (proc.stderr or "")
        if state:
            return state, raw
        # fall back to sacct for completed/failed
        proc = self.ssh.run(f"sacct -n -j {shlex.quote(job_id)} --format=State", check=False)
        state = (proc.stdout or "").strip().splitlines()[0] if (proc.stdout or "").strip() else ""
        raw = (proc.stdout or "") + (proc.stderr or "")
        return state, raw

    def read_logs(self, workdir: str, job_id: str, tail: Optional[int] = None, timestamps: bool = False, stream: str = "out") -> str:
        """
        Fetch the SLURM out/err log matching the pattern created by autolauncher: {output_filename}_%j_out.txt
        """
        suffix = "out" if stream != "err" else "err"
        # list newest matching files with job id
        cmd = f"ls -1t {shlex.quote(workdir)}/output/*_{shlex.quote(job_id)}_{suffix}.txt 2>/dev/null | head -n1"
        proc = self.ssh.run(cmd, check=False)
        path = (proc.stdout or "").strip()
        if not path:
            return ""
        if tail is None or tail <= 0:
            cat = self.ssh.run(f"cat {shlex.quote(path)}", check=False)
        else:
            cat = self.ssh.run(f"tail -n {int(tail)} {shlex.quote(path)}", check=False)
        return (cat.stdout or "")

