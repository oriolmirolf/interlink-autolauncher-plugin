import os
from dataclasses import dataclass


def env(key: str, default: str = "") -> str:
    return os.getenv(key, default)


def env_bool(key: str, default: bool = False) -> bool:
    v = os.getenv(key)
    if v is None:
        return default
    return str(v).strip().lower() in {"1", "true", "yes", "y", "on"}


@dataclass
class Settings:
    # --- Paths & command binaries ---
    AUTOLAUNCHER_PATH: str
    PYTHON_BIN: str = "python3"
    LOCAL_STAGING_DIR: str = "/tmp/interlink-autolauncher"
    STATE_FILE: str = "/var/lib/interlink-autolauncher/state.json"

    SSH_DEST: str = ""  # e.g. "ubuntu@slurm-master" (optional)

    SBATCH_BIN: str = "sbatch"
    SQUEUE_BIN: str = "squeue"
    SACCT_BIN: str = "sacct"
    SCANCEL_BIN: str = "scancel"

    # --- Defaults for autolauncher config ---
    DEFAULT_CLUSTER: str = "amd"  # or "mn4", "p9", "local"
    DEFAULT_WORKDIR: str = "/gpfs/projects/bsc70/hpai/work"
    DEFAULT_CONTAINERDIR: str = "/gpfs/projects/bsc70/hpai/containers/my-sandbox"
    DEFAULT_SINGULARITY_VERSION: str = "3.6.4"
    DEFAULT_BINARY: str = "python"
    DEFAULT_ADD_COMMIT_TAG: bool = False
    DEFAULT_USE_CODE_IN_GPFS: bool = True

    DEFAULT_QOS: str = "debug"
    DEFAULT_WALLTIME: str = "00:30:00"
    DEFAULT_NTASKS: int = 1
    DEFAULT_CPUS_PER_TASK: int = 4

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            AUTOLAUNCHER_PATH=env("IL_AUTOLAUNCHER_PATH", "/gpfs/projects/bsc70/hpai/vendor/autolauncher/autolauncher.py"),
            PYTHON_BIN=env("IL_PYTHON_BIN", "python3"),
            LOCAL_STAGING_DIR=env("IL_LOCAL_STAGING_DIR", "/tmp/interlink-autolauncher"),
            STATE_FILE=env("IL_STATE_FILE", "/var/lib/interlink-autolauncher/state.json"),
            SSH_DEST=env("IL_SSH_DEST", ""),
            SBATCH_BIN=env("IL_SBATCH_BIN", "sbatch"),
            SQUEUE_BIN=env("IL_SQUEUE_BIN", "squeue"),
            SACCT_BIN=env("IL_SACCT_BIN", "sacct"),
            SCANCEL_BIN=env("IL_SCANCEL_BIN", "scancel"),
            DEFAULT_CLUSTER=env("IL_DEFAULT_CLUSTER", "amd"),
            DEFAULT_WORKDIR=env("IL_DEFAULT_WORKDIR", "/gpfs/projects/bsc70/hpai/work"),
            DEFAULT_CONTAINERDIR=env("IL_DEFAULT_CONTAINERDIR", "/gpfs/projects/bsc70/hpai/containers/my-sandbox"),
            DEFAULT_SINGULARITY_VERSION=env("IL_DEFAULT_SINGULARITY_VERSION", "3.6.4"),
            DEFAULT_BINARY=env("IL_DEFAULT_BINARY", "python"),
            DEFAULT_ADD_COMMIT_TAG=env_bool("IL_DEFAULT_ADD_COMMIT_TAG", False),
            DEFAULT_USE_CODE_IN_GPFS=env_bool("IL_DEFAULT_USE_CODE_IN_GPFS", True),
            DEFAULT_QOS=env("IL_DEFAULT_QOS", "debug"),
            DEFAULT_WALLTIME=env("IL_DEFAULT_WALLTIME", "00:30:00"),
            DEFAULT_NTASKS=int(env("IL_DEFAULT_NTASKS", "1")),
            DEFAULT_CPUS_PER_TASK=int(env("IL_DEFAULT_CPUS_PER_TASK", "4")),
        )