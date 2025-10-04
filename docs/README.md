# InterLink ⇄ Autolauncher Plugin (fixed)

This version fixes:
- Correct package install path (keeps `plugin/` folder)
- Requirements installed from `plugin/requirements.txt`
- **UDS-first** operation (`~/.interlink/.plugin.sock`) so it matches interlink-installer defaults
- systemd runs `python -m plugin.run` and `ProtectHome=false` so the socket can be placed in `~/.interlink`
- Bootstrap auto-fills `interlink_ip` and enables `insecure_http: true` for quick tests
- Optional **socat** bridge for InterLink UDS → TCP:30433 (matches your working SLURM demo)

## Quick start
On autolauncher VM:
```
cd scripts
./bootstrap_autolauncher.sh
```
On k8s master:
```
cd scripts
./bootstrap_k8s_master.sh 192.168.0.98 <ssh-user> autolauncher-edge
```

## References
- Edge node deployment cookbook (OIDC/mTLS, installer): see docs.
- Plugin OpenAPI (required endpoints /create, /delete, /status, /getLogs).
- Helm values and `edge_with_socket` / `edge_with_rest` examples.

