from fastapi import FastAPI, HTTPException, Query, Body
from fastapi.responses import PlainTextResponse
import os
import yaml
from typing import List, Optional
import interlink

CONFIG_PATH = "/etc/autolauncher-plugin/config.yaml"
if not os.path.exists(CONFIG_PATH):
    raise RuntimeError(f"Config file {CONFIG_PATH} not found. Create it from config.yaml.example")

with open(CONFIG_PATH) as f:
    cfg = yaml.safe_load(f)

app = FastAPI()

# Initialize provider (the Autolauncher provider you already have)
from plugin.provider_autolauncher import AutolauncherProvider
provider = AutolauncherProvider(cfg)

@app.get("/health", response_class=PlainTextResponse)
def health():
    return "ok"

@app.post("/create")
def create_pod(pods: List[interlink.Pod]):
    return provider.create_pod(pods)

@app.post("/delete")
def delete_pod(pod: interlink.PodRequest):
    return provider.delete_pod(pod)

@app.get("/status")
def status_pod(
    # InterLink calls GET /status?pod_uid=<uid>&pod_uid=<uid>...
    pod_uid: Optional[List[str]] = Query(default=None, alias="pod_uid"),
    # Also accept alternate param name for convenience
    uid: Optional[List[str]] = Query(default=None, alias="uid"),
):
    ids = pod_uid or uid or []
    if not ids:
        # Return empty list instead of 500 — InterLink pings /status during /pinglink
        return []
    requests = [interlink.PodRequest(metadata=interlink.ObjectMeta(uid=i)) for i in ids]
    return provider.get_status(requests)

@app.get("/getLogs", response_class=PlainTextResponse)
def get_logs(
    pod_uid: str,
    container: str = "container",
    timestamps: bool = False,
    tail: str = "all",
):
    req = interlink.LogRequest(
        pod_uid=pod_uid,
        Container=container,
        Opts=interlink.LogOptions(Timestamps=timestamps, Tail=tail),
    )
    return provider.get_logs(req)
