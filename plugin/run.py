import os
import sys
import yaml
import pathlib
import uvicorn

# Ensure we can import plugin.main
sys.path.append(str(pathlib.Path(__file__).resolve().parent))

def main():
    config_path = os.environ.get("AUTOLAUNCHER_PLUGIN_CONFIG", "/etc/autolauncher-plugin/config.yaml")
    with open(config_path) as f:
        cfg = yaml.safe_load(f) or {}
    plugin_cfg = (cfg.get("plugin") or {})

    uds = plugin_cfg.get("uds")  # e.g. "~/.interlink/.plugin.sock"
    if uds:
        uds = os.path.expanduser(uds)
        # Prepare directory and remove stale socket
        os.makedirs(os.path.dirname(uds), exist_ok=True)
        try:
            os.remove(uds)
        except FileNotFoundError:
            pass
        uvicorn.run("plugin.main:app", uds=uds, log_level="info")
        return

    host = plugin_cfg.get("bind_host", "127.0.0.1")
    port = int(plugin_cfg.get("bind_port", 8001))
    uvicorn.run("plugin.main:app", host=host, port=port, log_level="info")

if __name__ == "__main__":
    main()
