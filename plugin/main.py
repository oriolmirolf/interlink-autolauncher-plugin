\
import os
import yaml
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
import interlink
from .provider_autolauncher import AutoLauncherProvider

app = FastAPI(title="InterLink Autolauncher Plugin", version="0.1.0")

# Load config
CONFIG_PATH = os.environ.get("AUTOLAUNCHER_PLUGIN_CONFIG", "/etc/autolauncher-plugin/config.yaml")
if not os.path.exists(CONFIG_PATH):
    raise RuntimeError(f"Config file {CONFIG_PATH} not found. Create it from config.yaml.example")

with open(CONFIG_PATH) as f:
    cfg = yaml.safe_load(f)

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
async def status_pod(pods: list[interlink.PodRequest]) -> list[interlink.PodStatus]:
    return provider.get_status(pods)

@app.get("/getLogs", response_class=PlainTextResponse)
async def get_logs(req: interlink.LogRequest):
    return (await provider.get_logs(req)).decode("utf-8")

if __name__ == "__main__":
    import uvicorn
    host = cfg.get("plugin", {}).get("bind_host", "127.0.0.1")
    port = int(cfg.get("plugin", {}).get("port", 8001))
    uvicorn.run("plugin.main:app", host=host, port=port, reload=False)
