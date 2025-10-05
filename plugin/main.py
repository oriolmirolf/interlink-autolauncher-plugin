import os
import yaml
from fastapi import FastAPI, Request
from fastapi.responses import PlainTextResponse
import interlink
from .provider_autolauncher import AutoLauncherProvider

app = FastAPI(title="InterLink Autolauncher Plugin", version="0.3.0")

CONFIG_PATH = os.environ.get("AUTOLAUNCHER_PLUGIN_CONFIG", "/etc/autolauncher-plugin/config.yaml")
try:
    if not os.path.exists(CONFIG_PATH):
        raise FileNotFoundError(CONFIG_PATH)
    with open(CONFIG_PATH) as f:
        cfg = yaml.safe_load(f) or {}
except PermissionError as e:
    raise RuntimeError(
        f"Cannot read {CONFIG_PATH} (permission denied). Fix chmod/chown so the service user can read it."
    ) from e
except FileNotFoundError:
    raise RuntimeError(f"Config file {CONFIG_PATH} not found. Create it from config.yaml.example")

provider = AutoLauncherProvider(cfg)

@app.get("/health", response_class=PlainTextResponse)
async def health():
    return "ok"

@app.post("/create")
async def create_pod(pods: list[interlink.Pod]) -> list[interlink.CreateStruct]:
    return provider.create_pod(pods)

@app.post("/delete")
async def delete_pod(pod: interlink.PodRequest) -> str:
    return provider.delete_pod(pod)

@app.get("/status")
async def status_pod(request: Request) -> list[interlink.PodStatus]:
    """
    InterLink 'ping' calls GET /status with no params/body -> must return [] with 200.
    Supports query: ?pod_uid=... (multi) and also ?uid=/ ?uids=.
    If JSON body is provided (list), extract metadata.uid entries.
    """
    # Query params first
    qp = request.query_params
    uids = qp.getlist("pod_uid") or qp.getlist("uid") or qp.getlist("uids")
    if uids:
        return provider.get_status_uids(uids)

    # Optional JSON body (some clients send a list)
    try:
        body = await request.json()
    except Exception:
        body = None

    if isinstance(body, list) and body:
        found = []
        for item in body:
            uid = None
            if isinstance(item, dict):
                uid = (
                    ((item.get("metadata") or {}).get("uid"))
                    or item.get("UID")
                    or item.get("uid")
                )
            if uid:
                found.append(uid)
        if found:
            return provider.get_status_uids(found)

    # No input -> empty list
    return []

@app.get("/getLogs", response_class=PlainTextResponse)
async def get_logs(req: interlink.LogRequest) -> bytes:
    return provider.get_logs(req)
