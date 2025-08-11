# interlink-autolauncher-deploy

One-command setup for:
- **Autolauncher VM**: run the Interlink Autolauncher Plugin (FastAPI/uvicorn) as a `systemd` service.
- **K8s worker**: expose the plugin to Interlink via a UNIX socket bridge using `socat`.

## Prereqs

**Autolauncher VM**
- Ubuntu 22.04+ (or 24.04)
- Git, Python 3.10+ (3.12 ok), venv
- Your plugin repo already cloned at `~/interlink-autolauncher-plugin`
  (it must contain `main.py`, `requirements.txt`, etc.)

**Worker VM**
- Ubuntu 22.04+ (or 24.04), `socat` package

## Quick start

### 1) Autolauncher VM
```bash
# on the autolauncher VM
cd scripts/autolauncher
./setup-plugin-host.sh
./status-plugin-host.sh
# health check
curl -sSf http://127.0.0.1:8001/health
````

### 2) Worker VM

```bash
# on the worker VM
cd scripts/worker
./setup-plugin-bridge.sh 192.168.0.98 8001
# health check via UNIX socket
curl -sSf --unix-socket /var/run/interlink/.plugin.sock http://unix/health
```

### Optional

* `./restart-plugin-host.sh`, `./uninstall-plugin-host.sh`
* `./restart-plugin-bridge.sh`, `./uninstall-plugin-bridge.sh`

## Notes

* The plugin’s on-disk state lives in `/var/lib/interlink-autolauncher-plugin` (created & chowned).
* The worker bridge creates `/var/run/interlink/.plugin.sock` (mode 666) so the Interlink pod can reach it.
