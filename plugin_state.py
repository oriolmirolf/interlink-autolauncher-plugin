import os, json, tempfile, threading
from typing import Any
from state import FileLock

_DEFAULT_PATH = os.environ.get("PLUGIN_STATE_PATH", "/var/lib/interlink-autolauncher-plugin/state.json")

class PluginState:
    def __init__(self, path: str = _DEFAULT_PATH):
        self.path = path
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        if not os.path.exists(self.path):
            self._write({"pods":{}})
        self._lock = FileLock(self.path + ".lock")

    def _read(self) -> dict:
        with open(self.path, "r") as f:
            return json.load(f)

    def _write(self, data: dict):
        d = os.path.dirname(self.path)
        os.makedirs(d, exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, self.path)

    def exists(self, uid: str) -> bool:
        with self._lock:
            db = self._read()
            return uid in db["pods"]

    def get(self, uid: str) -> dict | None:
        with self._lock:
            db = self._read()
            return db["pods"].get(uid)

    def upsert(self, uid: str, record: dict[str, Any]):
        with self._lock:
            db = self._read()
            db["pods"][uid] = record
            self._write(db)

    def remove(self, uid: str):
        with self._lock:
            db = self._read()
            db["pods"].pop(uid, None)
            self._write(db)
