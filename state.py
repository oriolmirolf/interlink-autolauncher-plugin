import json
from pathlib import Path
from typing import Dict, Any, Optional
import threading


class StateDB:
    def __init__(self, path: str):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        if not self.path.exists():
            self._write({})

    def _read(self) -> Dict[str, Any]:
        with self._lock:
            try:
                return json.loads(self.path.read_text())
            except Exception:
                return {}

    def _write(self, d: Dict[str, Any]):
        with self._lock:
            self.path.write_text(json.dumps(d, indent=2))

    def set(self, uid: str, value: Dict[str, Any]):
        d = self._read()
        d[uid] = value
        self._write(d)

    def get(self, uid: str) -> Optional[Dict[str, Any]]:
        return self._read().get(uid)

    def delete(self, uid: str):
        d = self._read()
        if uid in d:
            del d[uid]
            self._write(d)