import subprocess, time, uuid, datetime

def run(cmd, check=False, timeout=None, env=None):
    if isinstance(cmd, list):
        args = cmd
    else:
        args = cmd.split()
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env)
    if check and p.returncode != 0:
        raise subprocess.CalledProcessError(p.returncode, args, output=p.stdout, stderr=p.stderr)
    return type("R", (), {"returncode": p.returncode, "stdout": p.stdout, "stderr": p.stderr})

def gen_podjid() -> str:
    return uuid.uuid4().hex

def now_rfc3339() -> str:
    return datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc).isoformat()
