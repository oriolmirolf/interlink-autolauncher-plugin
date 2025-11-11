## How to run!

On slurm VM:
```bash
curl -fsSL -o slurmvm_interlink_edge_setup.sh https://example.invalid/slurmvm_interlink_edge_setup.sh
# (Or paste the script into this file manually)
chmod +x slurmvm_interlink_edge_setup.sh
./slurmvm_interlink_edge_setup.sh \
  IL_VERSION=0.5.1 \
  INTERLINK_HOST=0.0.0.0 \
  INTERLINK_PORT=30433
```

On k8 master VM:
```bash
curl -fsSL -o k8s_master_interlink_install.sh https://example.invalid/k8s_master_interlink_install.sh
# (Or paste the script into this file manually)
chmod +x k8s_master_interlink_install.sh
./k8s_master_interlink_install.sh \
  INTERLINK_HOST=192.168.0.3 \
  INTERLINK_PORT=30433 \
  NODE_NAME=slurm-edge \
  CHART_VER=0.5.2
```