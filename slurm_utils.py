import re
from dataclasses import dataclass
from typing import Optional, List
from datetime import datetime
import subprocess

from settings import Settings


@dataclass
class SlurmState:
    state: str
    reason: str = ""
    exit_code: Optional[int] = None
    started_at: Optional[str] = None  # RFC3339


class SlurmClient:
    def __init__(self, settings: Settings):
        self.s = settings

    def scancel(self, job_id: str) -> List[str]:
        return self._wrap([self.s.SCANCEL_BIN, job_id])

    def query_state(self, job_id: str) -> SlurmState:
        # Try squeue for active jobs
        rc, out, err = self._run(self._wrap([self.s.SQUEUE_BIN, "-h", "-j", job_id, "-o", "%T|%M|%S|%R"]))
        if rc == 0 and out.strip():
            # Example: RUNNING|00:01:33|2025-09-16T08:45:22|nid00001
            parts = out.strip().split("|")
            st = parts[0]
            started = None
            if len(parts) > 2 and parts[2]:
                try:
                    # Some squeue formats return epoch or date; be tolerant
                    started = parts[2]
                except Exception:
                    started = None
            return SlurmState(state=st, reason=parts[-1] if parts else "", started_at=started)

        # Else, sacct for finished jobs
        rc, out, err = self._run(self._wrap([self.s.SACCT_BIN, "-n", "-X", "-j", job_id, "-o", "State,ExitCode", "-P"]))
        if rc == 0 and out.strip():
            # Example: COMPLETED|0:0
            line = out.strip().splitlines()[0]
            fields = line.split("|")
            state = fields[0].strip()
            exit_code = None
            if len(fields) > 1:
                m = re.match(r"(\d+):(\d+)", fields[1].strip())
                if m:
                    exit_code = int(m.group(1))
            return SlurmState(state=state, exit_code=exit_code)

        # Unknown — treat as completed w/ missing info
        return SlurmState(state="COMPLETED")

    # ---------- helpers ----------
    def _sshwrap(self, base):
        import os
        use = os.getenv("IL_SSH_USE_SSHPASS", "0").lower() in ("1", "true", "yes")
        pw  = os.getenv("IL_SSH_PASS", "")
        if self.s.SSH_DEST and use and pw:
            return ["sshpass", "-p", pw] + base
        return base

    def _wrap(self, base: List[str]) -> List[str]:
        if self.s.SSH_DEST:
            joined = " ".join([shlex_quote(x) for x in base])
            return self._sshwrap(["ssh", self.s.SSH_DEST, "bash", "-lc", joined])
        return base

    def _run(self, cmd: List[str]):
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, check=False)
            return p.returncode, (p.stdout or ""), (p.stderr or "")
        except Exception as e:
            return 1, "", str(e)


# Simple, self-contained shell quoting
def shlex_quote(s: str) -> str:
    if not s:
        return "''"
    if re.search(r"[^A-Za-z0-9_@%+=:,./-]", s):
        return "'" + s.replace("'", "'\\''") + "'"
    return s
