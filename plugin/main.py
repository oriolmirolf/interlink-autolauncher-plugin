import logging
import os
import json
from typing import Optional
from fastapi import FastAPI, HTTPException, Request
import uvicorn
import interlink
from plugin.provider_autolauncher import AutolauncherProvider

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("autolauncher-plugin")

config_path = os.environ.get("INTERLINK_CONFIG_PATH", "/opt/interlink-autolauncher-plugin/config.json")
try:
    with open(config_path) as f: cfg = json.load(f)
except Exception as e:
    cfg = {}
    logger.warning(f"Could not load config: {e}")

provider = AutolauncherProvider(cfg)
app = FastAPI()

@app.get("/status")
async def status(): return {"status": "ok"}

@app.post("/create")
async def create_pod(pod: dict):
    try:
        provider.create(pod)
        return {"status": "created"}
    except Exception as e:
        logger.error(f"Create failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/delete")
async def delete_pod(pod: dict):
    try:
        provider.delete(pod)
        return {"status": "deleted"}
    except Exception as e:
        logger.error(f"Delete failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/getLogs")
async def get_logs(request: Request):
    try:
        # Check Query Params first, then Body
        params = dict(request.query_params)
        if not params:
            try:
                body = await request.json()
                if body: params = body
            except: pass

        uid = params.get("PodUID") or params.get("podUID") or params.get("uid") or params.get("pod_uid")
        
        if not uid:
            raise HTTPException(status_code=400, detail=f"Missing PodUID. Received: {list(params.keys())}")

        opts = interlink.LogOpts(
            Tail=int(params.get("Tail", 0)) if params.get("Tail") else None,
            LimitBytes=None,
            Timestamps=str(params.get("Timestamps")).lower() == "true",
            Follow=False, Previous=False, SinceSeconds=None, SinceTime=None
        )
        
        class SimpleLogRequest:
            def __init__(self, u, o): self.pod_uid = u; self.Opts = o
        
        # KEY CHANGE: Return as Raw Text, not JSON
        logs = provider.get_logs(SimpleLogRequest(uid, opts))
        return Response(content=logs, media_type="text/plain")
        
    except Exception as e:
        logger.error(f"GetLogs failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import sys
    socket_path = sys.argv[1] if len(sys.argv) > 1 else "/var/run/interlink/plugin.sock"
    if os.path.exists(socket_path): os.remove(socket_path)
    uvicorn.run(app, uds=socket_path, log_level="info")
