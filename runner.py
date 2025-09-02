# runner.py
import os, json, shlex, re, posixpath
import yaml
import paramiko
from utils import run, now_rfc3339


def _parse_bool(v, default=True) -> bool:
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    return s in ("1", "true", "yes", "y", "on")


def _normalize_gres(gres: str | None) -> str | None:
    """Accept '1', 'gpu:1', 'gpu:a100:1' -> return numeric count as str ('1')."""
    if not gres:
        return None
    s = str(gres).strip()
    if s.isdigit():
        return s
    parts = s.split(":")
    if parts and parts[-1].isdigit():
        return parts[-1]
    return None


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
        cmd = ["docker", "run", "-d", "--name", name, image]
        if command:
            cmd.extend(command)
        if args:
            cmd.extend(args)
        r = run(cmd, check=True)
        jid = r.stdout.strip() or name
        return jid

    def status(self, jid: str) -> dict:
        r = run(["docker", "inspect", jid, "--format", "{{json .State}}"], check=False)
        if r.returncode != 0:
            return {"phase": "Failed", "reason": "NotFound"}
        st = json.loads(r.stdout.strip())
        if st.get("Running"):
            started = st.get("StartedAt") or now_rfc3339()
            return {"phase": "Running", "startedAt": started}
        if st.get("Status") == "exited" and int(st.get("ExitCode", 1)) == 0:
            return {"phase": "Succeeded"}
        return {"phase": "Failed", "reason": st.get("Error") or st.get("Status", "Unknown")}

    def logs(self, jid: str, tail: int | None, previous: bool, timestamps: bool | None) -> str:
        cmd = ["docker", "logs"]
        if tail is not None:
            cmd += ["--tail", str(tail)]
        if timestamps:
            cmd += ["--timestamps"]
        cmd += [jid]
        r = run(cmd, check=False)
        return r.stdout

    def delete(self, jid: str):
        run(["docker", "rm", "-f", jid], check=False)


class HPCRunner:
    """
    HPC (SSH + SLURM) runner bound to the vendored Autolauncher script.

    It:
      - reads targets from PLUGIN_TARGETS_FILE (YAML)
      - SSHes to the login node
      - creates a per-job workdir
      - uploads autolauncher.py and a config.json
      - runs:  python autolauncher.py --file ... --workdir ... --containerdir ...
               (no --cluster CLI: JSON config decides launcher)
      - parses "Submitted batch job <id>"
      - status via squeue/sacct
      - logs via tail on output/*_<id>_out.txt (fallback: slurm_output/out.txt)

    Auth per-target:
      - SSH key (default): set 'ssh_key' path in targets.yml
      - Password: set 'auth: password', plus 'user_env'/'user' and 'password_env' in targets.yml.
    """

    def __init__(self, target: str = "amd"):
        self.target_name = target
        self.targets_file = os.getenv("PLUGIN_TARGETS_FILE", "/etc/interlink-autolauncher-plugin/targets.yml")

        # Read the targets file every time an instance is created.
        try:
            with open(self.targets_file, "r") as f:
                cfg = yaml.safe_load(f) or {}
        except FileNotFoundError:
            raise RuntimeError(f"Targets file not found at: {self.targets_file}")

        self.target = (cfg.get("targets") or {}).get(target)
        if not self.target:
            available_keys = list((cfg.get('targets') or {}).keys())
            raise RuntimeError(f"Unknown HPC target '{target}'. Available in {self.targets_file}: {available_keys}")

        configured = os.getenv("AUTOLAUNCHER_LOCAL_PATH")
        default_vendor = os.path.join(os.getcwd(), "vendor", "autolauncher", "autolauncher.py")
        default_toplvl = os.path.join(os.getcwd(), "autolauncher", "autolauncher.py")
        candidates = [p for p in [configured, default_vendor, default_toplvl] if p]

        self.autolauncher_local = None
        for c in candidates:
            if c and os.path.exists(c):
                self.autolauncher_local = c
                break
        if not self.autolauncher_local:
            raise RuntimeError(
                "autolauncher.py not found. Tried: "
                + ", ".join([x for x in candidates if x])
                + ". Set AUTOLAUNCHER_LOCAL_PATH or add the file."
            )

    # ---------- SSH helpers ----------
    def _resolve_user(self) -> str:
        env_key = self.target.get("user_env")
        if env_key:
            val = os.environ.get(env_key)
            if val:
                return val
        user = self.target.get("user")
        if not user:
            raise RuntimeError("No username found. Set 'user' or 'user_env' in targets.yml.")
        return user

    def _connect(self) -> paramiko.SSHClient:
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        user = self._resolve_user()
        auth_mode = (self.target.get("auth") or "ssh-key").lower()
        kwargs = dict(
            hostname=self.target["host"],
            username=user,
            look_for_keys=False,
            allow_agent=False,
            timeout=20,
        )
        if auth_mode == "password":
            pw_env = self.target.get("password_env")
            if not pw_env:
                raise RuntimeError("password_env is required for auth=password")
            pw_val = os.environ.get(pw_env)
            if not pw_val:
                raise RuntimeError(f"Environment variable '{pw_env}' is empty or not set")
            kwargs["password"] = pw_val
        else:
            key_path = self.target.get("ssh_key")
            if not key_path:
                raise RuntimeError("ssh_key is required for auth=ssh-key")
            kwargs["key_filename"] = key_path

        c.connect(**kwargs)
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
        pieces: list[str] = []
        if command:
            pieces += command
        if args:
            pieces += args
        if len(pieces) >= 2 and pieces[0] in ("bash", "/bin/bash") and pieces[1] in ("-lc", "-c"):
            pieces = pieces[2:]
        shell = " ".join(shlex.quote(x) for x in pieces) if pieces else "echo start; sleep 3; echo done"
        return ("/bin/bash", "-lc", shell)

    # ---------- API ----------
    def launch_hpc(self, uid: str, namespace: str, image: str, command: list[str], args: list[str],
                   annotations: dict[str, str] | None = None) -> str:
        a = annotations or {}

        container_ref = (a.get("interlink.autolauncher/containerref") or "").strip()
        if not container_ref:
            raise RuntimeError("Missing annotation 'interlink.autolauncher/containerref' (container sandbox folder name).")

        qos       = a.get("interlink.autolauncher/qos", self.target.get("qos", "debug"))
        account   = a.get("interlink.autolauncher/account", self.target.get("account", None))
        partition = a.get("interlink.autolauncher/partition", self.target.get("partition", None))
        wall      = a.get("interlink.autolauncher/time", "00:10:00")
        ntasks    = int(a.get("interlink.autolauncher/ntasks", "1"))
        cpt       = int(a.get("interlink.autolauncher/cpus-per-task", "1"))
        # cluster / singularity version (JSON must drive autolauncher behavior)
        cluster   = a.get("interlink.autolauncher/cluster", self.target.get("cluster", "amd"))
        singv     = a.get("interlink.autolauncher/singularity_version", self.target.get("singularity_version", "3.6.4"))
        use_gpfs  = _parse_bool(a.get("interlink.autolauncher/use_code_in_gpfs"), True)
        gres_norm = _normalize_gres(a.get("interlink.autolauncher/gres"))

        if account in (None, "",):
            raise RuntimeError("No SLURM account set. Provide 'interlink.autolauncher/account' or set 'account' in the target config.")

        job_dir      = posixpath.join(self.target["workdir_base"], uid)
        config_dir   = posixpath.join(job_dir, "configs")
        output_dir   = posixpath.join(job_dir, "output")
        containerdir = posixpath.join(self.target["containerdir_base"], container_ref)

        binary, cmd_flag, shell_line = self._shell_from_k8s(command, args)

        bindings_list: list[str] = []
        extra_bind = (a.get("interlink.autolauncher/bind") or "").strip()
        if extra_bind:
            for b in extra_bind.split(","):
                b = b.strip()
                if b:
                    bindings_list.append(b)

        config = {
            "cluster": cluster,                 # <— JSON decides the launcher
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
            "use_code_in_gpfs": use_gpfs,
            "singularity_version": singv,
        }
        # Only AMD launcher consumes 'gres' (as an integer). MN4 ignores it.
        if gres_norm and cluster == "amd":
            config["gres"] = gres_norm
        if bindings_list:
            config["bindings_list"] = bindings_list

        c = self._connect()
        try:
            mk = f"mkdir -p {shlex.quote(job_dir)} {shlex.quote(config_dir)} {shlex.quote(output_dir)}"
            rc, out, err = self._ssh(c, mk)
            if rc != 0:
                raise RuntimeError(f"Failed to create job dirs. rc={rc}\nSTDERR:\n{err}\nSTDOUT:\n{out}")

            sftp = c.open_sftp()
            try:
                self._sftp_mkdirs(sftp, job_dir)
                self._sftp_mkdirs(sftp, config_dir)
                self._sftp_mkdirs(sftp, output_dir)

                with open(self.autolauncher_local, "rb") as f:
                    sftp.putfo(f, posixpath.join(job_dir, "autolauncher.py"))

                cfg_text = json.dumps(config, indent=2)
                with sftp.file(posixpath.join(config_dir, "config.json"), "w") as rf:
                    rf.write(cfg_text)
            finally:
                sftp.close()

            # Build env prefix for sbatch
            env_pairs = []
            if account:
                env_pairs.append(f"SBATCH_ACCOUNT={shlex.quote(account)}")
            if partition:
                env_pairs.append(f"SBATCH_PARTITION={shlex.quote(partition)}")
            if qos:
                env_pairs.append(f"SBATCH_QOS={shlex.quote(qos)}")
            env_prefix = ("env " + " ".join(env_pairs) + " ") if env_pairs else ""

            # IMPORTANT: do NOT pass --cluster here; JSON already contains it.
            py = self.target.get("python", "python3")
            cmd = (
                f'{env_prefix}{py} autolauncher.py '
                f'--file {shlex.quote(posixpath.join(config_dir, "config.json"))} '
                f'--workdir {shlex.quote(job_dir)} '
                f'--containerdir {shlex.quote(containerdir)}'
            )
            rc, out, err = self._ssh(c, cmd, cwd=job_dir)
            combined = (out or "") + "\n" + (err or "")
            m = re.search(r"Submitted batch job\s+(\d+)", combined)
            if not m:
                raise RuntimeError(f"Could not parse SLURM JobId. Output:\n{combined}")
            jid = m.group(1).strip()
            return jid
        finally:
            c.close()

    def status_hpc(self, jid: str) -> dict:
        c = self._connect()
        try:
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

            rc, out, _ = self._ssh(c, f'sacct -n -j {shlex.quote(jid)} --format=State%20 | head -n1 || true')
            sacct_state = (out.strip() or "").upper()
            if "COMPLETED" in sacct_state:
                return {"phase": "Succeeded"}
            if sacct_state:
                return {"phase": "Failed", "reason": sacct_state}
            return {"phase": "Failed", "reason": "Unknown"}
        finally:
            c.close()

    def logs_hpc(self, jid: str, tail: int | None) -> str:
        n = tail or 200
        c = self._connect()
        try:
            cmd = f'''
                set -e
                f=$(ls -1 {self.target["workdir_base"]}/*/output/*_{shlex.quote(jid)}_out.txt 2>/dev/null | tail -n1) || true
                if [ -n "$f" ]; then echo "===== $f ====="; tail -n {n} "$f"; fi
                g=$(ls -1 {self.target["workdir_base"]}/*/output/*_{shlex.quote(jid)}_err.txt 2>/dev/null | tail -n1) || true
                if [ -n "$g" ]; then echo; echo "===== $g ====="; tail -n {n} "$g"; exit 0; fi
                if [ -z "$f" ] && [ -z "$g" ]; then
                  h=$(ls -1 {self.target["workdir_base"]}/*/slurm_output/* 2>/dev/null | tail -n1) || true
                  if [ -n "$h" ]; then tail -n {n} "$h"; exit 0; fi
                  echo "No logs found yet for Job {jid}."
                fi
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
