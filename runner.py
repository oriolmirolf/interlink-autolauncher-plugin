import os, json, time, shlex, re, io, posixpath
import yaml
import paramiko
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
    HPC (SSH + SLURM) runner bound to the vendored Autolauncher script.

    It:
      - reads targets from PLUGIN_TARGETS_FILE (YAML)
      - SSHes to the login node
      - creates a per-job workdir
      - uploads autolauncher.py and a config.json
      - runs:  python autolauncher.py --cluster ... --file ... --workdir ... --containerdir ...
      - parses "Submitted batch job <id>"
      - status via squeue/sacct
      - logs via tail on output/*_<id>_out.txt (fallback: slurm_output/out.txt)
      - delete via scancel
    """

    def __init__(self, target: str = "amd"):
        self.target_name = target
        self.targets_file = os.getenv("PLUGIN_TARGETS_FILE", "/etc/interlink-autolauncher-plugin/targets.yml")

        # Locate autolauncher.py robustly without changing any scripts:
        # 1) AUTOLAUNCHER_LOCAL_PATH (from systemd unit)
        # 2) ./vendor/autolauncher/autolauncher.py
        # 3) ./autolauncher/autolauncher.py  (your repo layout)
        configured = os.getenv("AUTOLAUNCHER_LOCAL_PATH")
        default_vendor = os.path.join(os.getcwd(), "vendor", "autolauncher", "autolauncher.py")
        default_toplvl = os.path.join(os.getcwd(), "autolauncher", "autolauncher.py")

        candidates = [p for p in [configured, default_vendor, default_toplvl] if p]
        self.autolauncher_local = None
        for c in candidates:
            if os.path.exists(c):
                self.autolauncher_local = c
                break
        if not self.autolauncher_local:
            raise RuntimeError(
                "autolauncher.py not found. Tried: "
                + ", ".join(candidates)
                + ". Set AUTOLAUNCHER_LOCAL_PATH or add the file."
            )

        with open(self.targets_file, "r") as f:
            cfg = yaml.safe_load(f) or {}
        self.target = (cfg.get("targets") or {}).get(target)
        if not self.target:
            raise RuntimeError(f"Unknown HPC target '{target}'. Available: {list((cfg.get('targets') or {}).keys())}")

    # ---------- SSH helpers ----------
    def _connect(self) -> paramiko.SSHClient:
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(
            hostname=self.target["host"],
            username=self.target["user"],
            key_filename=self.target["ssh_key"],
            look_for_keys=False,
            allow_agent=False,
            timeout=20,
        )
        return c

    @staticmethod
    def _sftp_mkdirs(sftp: paramiko.SFTPClient, path: str):
        parts = path.strip("/").split("/")
        cur = "/"
        for p in parts:
            cur = posixpath.join(cur, p)
            try:
                sftp.mkdir(cur)
            except IOError:
                pass

    @staticmethod
    def _ssh(c: paramiko.SSHClient, cmd: str, cwd: str | None = None) -> tuple[int, str, str]:
        if cwd:
            cmd = f"cd {shlex.quote(cwd)} && {cmd}"
        stdin, stdout, stderr = c.exec_command(cmd)
        rc = stdout.channel.recv_exit_status()
        return rc, stdout.read().decode(), stderr.read().decode()

    # ---------- mapping ----------
    @staticmethod
    def _shell_from_k8s(command: list[str] | None, args: list[str] | None) -> tuple[str, str, str]:
        """
        Map K8s container command/args -> autolauncher (binary, command, args).
        We use /bin/bash -lc "<joined shell>" to preserve semantics.
        """
        pieces: list[str] = []
        if command:
            pieces += command
        if args:
            pieces += args
        shell = " ".join(shlex.quote(x) for x in pieces) if pieces else "echo start; sleep 3; echo done"
        return ("/bin/bash", "-lc", shell)

    # ---------- API ----------
    def launch_hpc(self, uid: str, namespace: str, image: str, command: list[str], args: list[str],
                   annotations: dict[str, str] | None = None) -> str:
        a = annotations or {}
        container_ref = a.get("interlink.autolauncher/containerref", "").strip()
        if not container_ref:
            raise RuntimeError("Missing annotation 'interlink.autolauncher/containerref' (container sandbox folder name).")

        qos = a.get("interlink.autolauncher/qos", "debug")
        wall = a.get("interlink.autolauncher/time", "00:10:00")
        ntasks = int(a.get("interlink.autolauncher/ntasks", "1"))
        cpt = int(a.get("interlink.autolauncher/cpus-per-task", "1"))

        job_dir = posixpath.join(self.target["workdir_base"], uid)
        config_dir = posixpath.join(job_dir, "configs")
        output_dir = posixpath.join(job_dir, "output")
        containerdir = posixpath.join(self.target["containerdir_base"], container_ref)

        binary, cmd_flag, shell_line = self._shell_from_k8s(command, args)

        config = {
            # Autolauncher params:
            "cluster": self.target["cluster"],      # e.g., amd | mn4
            "workdir": job_dir,
            "containerdir": containerdir,
            "qos": qos,
            "time": wall,
            "ntasks": ntasks,
            "cpus-per-task": cpt,
            "binary": binary,
            "command": cmd_flag,
            "args": shell_line,
            "add_commit_tag": False,
            "use_code_in_gpfs": True,
        }

        # ship files and run
        c = self._connect()
        try:
            sftp = c.open_sftp()
            try:
                self._sftp_mkdirs(sftp, config_dir)
            finally:
                pass

            # upload autolauncher.py
            with open(self.autolauncher_local, "rb") as f:
                sftp.putfo(f, posixpath.join(job_dir, "autolauncher.py"))

            # upload config.json
            cfg_bytes = json.dumps(config, indent=2).encode()
            with sftp.file(posixpath.join(config_dir, "config.json"), "w") as rf:
                rf.write(cfg_bytes.decode())

            # ensure output dir exists (autolauncher will do it too; harmless)
            self._sftp_mkdirs(sftp, output_dir)
            sftp.close()

            # launch
            py = self.target.get("python", "python3")
            cmd = f'{py} autolauncher.py --cluster {shlex.quote(self.target["cluster"])} ' \
                  f'--file {shlex.quote(posixpath.join(config_dir,"config.json"))} ' \
                  f'--workdir {shlex.quote(job_dir)} ' \
                  f'--containerdir {shlex.quote(containerdir)}'
            rc, out, err = self._ssh(c, cmd, cwd=job_dir)
            combined = out + "\n" + err
            m = re.search(r"Submitted batch job\s+(\d+)", combined)
            if not m:
                # When cluster=local it might not print the sbatch line (shouldn’t happen here)
                raise RuntimeError(f"Could not parse SLURM JobId. Output:\n{combined}")
            jid = m.group(1).strip()
            return jid
        finally:
            c.close()

    def status_hpc(self, jid: str) -> dict:
        c = self._connect()
        try:
            # Prefer squeue; if absent, fall back to sacct
            rc, out, _ = self._ssh(c, f'squeue -h -j {shlex.quote(jid)} -o "%T" || true')
            state = (out.strip().splitlines() or [""])[0].upper()
            if state:
                phase_map = {
                    "RUNNING": "Running",
                    "PENDING": "Pending",
                    "COMPLETING": "Running",
                    "CONFIGURING": "Pending",
                    "COMPLETED": "Succeeded",
                    "FAILED": "Failed",
                    "CANCELLED": "Failed",
                    "TIMEOUT": "Failed",
                    "PREEMPTED": "Failed",
                    "NODE_FAIL": "Failed",
                }
                phase = phase_map.get(state, "Pending")
                out = {"phase": phase}
                if phase == "Running":
                    out["startedAt"] = now_rfc3339()
                return out

            # not in squeue -> finished; check sacct
            rc, out, _ = self._ssh(c, f'sacct -n -j {shlex.quote(jid)} --format=State%20 | head -n1 || true')
            sacct_state = (out.strip() or "").upper()
            if "COMPLETED" in sacct_state:
                return {"phase": "Succeeded"}
            if sacct_state:
                return {"phase": "Failed", "reason": sacct_state}
            # best effort
            return {"phase": "Failed", "reason": "Unknown"}
        finally:
            c.close()

    def logs_hpc(self, jid: str, tail: int | None) -> str:
        n = tail or 200
        c = self._connect()
        try:
            job_dir = posixpath.join(self.target["workdir_base"], "*")  # we don’t know uid here; try glob
            # Prefer autolauncher default output files containing _<jid>_
            cmd = f'''
                set -e
                f=$(ls -1 {self.target["workdir_base"]}/*/output/*_{shlex.quote(jid)}_out.txt 2>/dev/null | tail -n1) || true
                if [ -n "$f" ]; then tail -n {n} "$f"; exit 0; fi
                # fallback used in some templates
                g=$(ls -1 {self.target["workdir_base"]}/*/slurm_output/* 2>/dev/null | tail -n1) || true
                if [ -n "$g" ]; then tail -n {n} "$g"; exit 0; fi
                echo "No logs found yet for Job {jid}."
            '''
            rc, out, err = self._ssh(c, cmd)
            return out if out else err
        finally:
            c.close()

    def delete_hpc(self, jid: str):
        c = self._connect()
        try:
            self._ssh(c, f"scancel {shlex.quote(jid)} || true")
        finally:
            c.close()
