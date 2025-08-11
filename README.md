# interlink-autolauncher-plugin

InterLink sidecar plugin that adapts `/create`, `/status`, `/getLogs`, `/delete` into **Autolauncher** actions.
Supports:
- **local** mode (runs containers via Docker; great for CI/smoke)
- **hpc** mode (stubs provided; wire to your SSH/SLURM site)

## Endpoints
- `GET  /health` → `{status:"ok"}`
- `POST /create`  → `[{"PodUID":"...","PodJID":"..."}]`
- `GET  /status`  (JSON body) → `[PodStatus]`
- `GET  /getLogs` (JSON body) → `text/plain`
- `POST /delete`  → `"OK"`

## Run (host, with venv)
```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export PLUGIN_MODE=local
uvicorn main:app --host 0.0.0.0 --port 8001
```

## Run (systemd)
```bash
sudo ./scripts/install-systemd.sh
sudo systemctl enable --now interlink-autolauncher-plugin
```

## Run (container)
Build and run; ensure Docker CLI/daemon accessible or mount `/var/run/docker.sock.`
```bash 
docker build -t interlink-autolauncher-plugin:dev .
docker run --rm -p 8001:8001 \
  -e PLUGIN_MODE=local \
  -v /var/run/docker.sock:/var/run/docker.sock \
  interlink-autolauncher-plugin:dev
```

## Smoke test
```bash
./scripts/smoke.sh http://127.0.0.1:8001
```