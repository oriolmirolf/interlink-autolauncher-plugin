from fastapi import FastAPI, HTTPException, Body, Query
from fastapi.responses import PlainTextResponse
from typing import List, Optional
import os, yaml
import interlink

from plugin.provider_autolauncher import AutolauncherProvider

CONFIG_PATH = os.getenv("AUTOLAUNCHER_PLUGIN_CONFIG", "/etc/autolauncher-plugin/config.yaml")
try:
    with open(CONFIG_PATH) as f:
        _cfg = yaml.safe_load(f) or {}
except FileNotFoundError:
    _cfg = {}

app = FastAPI(title="InterLink Autolauncher Plugin")
provider = AutolauncherProvider(_cfg)

@app.get("/health", response_class=PlainTextResponse)
def health() -> str:
    return "ok"

@app.get("/status")
def status_get(pod_uid: Optional[List[str]] = Query(default=None)) -> List[interlink.PodStatus]:
    if not pod_uid:
        return []
    reqs = [interlink.PodRequest(metadata=interlink.ObjectMeta(uid=uid, name="", namespace="")) for uid in pod_uid]
    return provider.get_status(reqs)

@app.post("/status")
def status_post(pods: List[interlink.PodRequest] = Body(...)) -> List[interlink.PodStatus]:
    return provider.get_status(pods or [])

@app.post("/create")
def create_pods(pods: List[interlink.Pod] = Body(...)) -> List[interlink.CreateStruct]:
    try:
        return provider.create_pod(pods)
    except Exception as ex:
        raise HTTPException(status_code=500, detail=str(ex))

@app.post("/delete")
def delete_pod(pod: interlink.PodRequest = Body(...)) -> str:
    try:
        return provider.delete_pod(pod)
    except Exception as ex:
        raise HTTPException(status_code=500, detail=str(ex))

@app.get("/getLogs", response_class=PlainTextResponse)
def get_logs(pod_uid: str, container: str, tail: Optional[int] = None, timestamps: bool = False) -> bytes:
    try:
        req = interlink.LogRequest(pod_uid=pod_uid, Container=container,
                                   Opts=interlink.LogOpts(Tail=tail or 0, Timestamps=timestamps))
        return provider.get_logs(req)
    except Exception as ex:
        raise HTTPException(status_code=500, detail=str(ex))
