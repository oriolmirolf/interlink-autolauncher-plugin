import os, yaml
from uvicorn import run
from plugin.main import app

CONFIG_PATH = os.environ.get("AUTOLAUNCHER_PLUGIN_CONFIG", "/etc/autolauncher-plugin/config.yaml")
if not os.path.exists(CONFIG_PATH):
    raise SystemExit(f"Config file {CONFIG_PATH} not found")

with open(CONFIG_PATH, "r") as f:
    cfg = yaml.safe_load(f) or {}

p = cfg.get("plugin", {})

uds = os.path.expanduser(p.get("uds", "~/.interlink/.plugin.sock"))
bind_host = p.get("bind_host", "127.0.0.1")
port = int(p.get("port", 8001))

# Ensure directory for UDS
if uds:
    try:
        os.makedirs(os.path.dirname(uds), exist_ok=True)
    except Exception:
        pass

if uds:
    try:
        if os.path.exists(uds):
            os.remove(uds)
    except Exception:
        pass
    run(app, uds=uds, log_level="info")
else:
    run(app, host=bind_host, port=port, log_level="info")
