import os, fcntl, time

class FileLock:
    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.fd = None

    def __enter__(self):
        self.fd = open(self.path, "a+")
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            self.fd.close()
        finally:
            self.fd = None
