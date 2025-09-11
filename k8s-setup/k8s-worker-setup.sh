#!/usr/bin/env bash
set -euo pipefail

# ===== Config you may tweak =====
K8S_MAJOR_MINOR="1.28"
K8S_VERSION_PIN="${K8S_MAJOR_MINOR}.*"  # pin family
# Provide join command by either:
#   1) exporting JOIN_CMD env var before running, e.g.:
#      export JOIN_CMD="kubeadm join 192.168.0.249:6443 --token xxx --discovery-token-ca-cert-hash sha256:yyy"
#   2) passing it as a single argument to this script:
#      ./k8s-worker-setup.sh "kubeadm join 192.168.0.249:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
# =================================

JOIN_CMD="${JOIN_CMD:-${1:-}}"

log() { printf '\n\033[1;36m[WORKER]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[ERR]\033[0m %s\n' "$*"; exit 1; }

# 0) Basic packages + optional firewall disable (dev only)
log "Updating & installing base tools"
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl gpg gnupg2 lsb-release software-properties-common net-tools conntrack

if command -v ufw >/dev/null 2>&1; then
  warn "Disabling UFW (DEV ONLY). In production, open only required ports."
  sudo ufw disable || true
fi

# 1) Swap off + keep off
log "Disabling swap"
sudo swapoff -a
sudo sed -i.bak -r 's/(.+[[:space:]]swap[[:space:]].+)/#\1/' /etc/fstab
free -m | awk '/Swap/ {print "Swap now:", $0}'

# 2) Kernel modules + sysctl
log "Configuring required kernel modules & sysctl"
echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

# 3) Install containerd from Docker repo
log "Installing containerd.io"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
 | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
 | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update -y
sudo apt install -y containerd.io cri-tools

# Configure containerd (SystemdCgroup=true, disabled_plugins=[])
log "Configuring containerd (SystemdCgroup=true)"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/^disabled_plugins.*/disabled_plugins = \[\]/' /etc/containerd/config.toml || true
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
sudo systemctl enable --now containerd

# crictl talks to containerd
cat <<'EOF' | sudo tee /etc/crictl.yaml >/dev/null
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 2
debug: false
EOF

# 4) Add ONLY Kubernetes v1.28 repo + pin
log "Adding Kubernetes ${K8S_MAJOR_MINOR}.x repo & pinning"
sudo rm -f /etc/apt/sources.list.d/*kubernetes* /etc/apt/sources.list.d/*pkgs.k8s.io* || true
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key \
 | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" \
 | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo tee /etc/apt/preferences.d/kubernetes >/dev/null <<EOF
Package: kubeadm kubelet kubectl
Pin: version ${K8S_VERSION_PIN}
Pin-Priority: 1001
EOF

sudo apt update -y
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 5) Clean any previous join attempts
log "Cleaning any previous kubeadm state"
sudo systemctl stop kubelet || true
sudo kubeadm reset -f || true
sudo umount -R /var/lib/kubelet 2>/dev/null || true
sudo rm -rf /var/lib/kubelet/* /etc/cni/net.d /var/lib/cni || true
sudo systemctl enable --now kubelet

# 6) Make sure we're using the APT kubeadm (avoid stray /usr/local/bin)
if command -v kubeadm >/dev/null 2>&1; then
  # If /usr/local/bin/kubeadm exists and is NOT 1.28, move it aside
  if [ -x /usr/local/bin/kubeadm ]; then
    V=$(/usr/local/bin/kubeadm version 2>/dev/null | sed -n 's/.*GitVersion:"v\([0-9.]*\)".*/\1/p' || true)
    if [ "$V" != "1.28.15" ] && [ "$V" != "1.28.14" ] && [ -n "$V" ]; then
      log "Found non-1.28 kubeadm at /usr/local/bin (v$V); moving it aside"
      sudo mv /usr/local/bin/kubeadm /usr/local/bin/kubeadm.bak.$(date +%s)
      hash -r || true
    fi
  fi
fi

log "kubeadm versions:"
type -a kubeadm || true
kubeadm version || true
/usr/bin/kubeadm version || true

# 7) Run the join
if [ -z "${JOIN_CMD}" ]; then
  die "JOIN_CMD not provided. Either export JOIN_CMD=\"kubeadm join ...\" or pass it as the first argument."
fi

log "Joining cluster with containerd socket"
# Append CRI socket + verbosity if not already present
if ! echo "$JOIN_CMD" | grep -q -- '--cri-socket'; then
  JOIN_CMD="$JOIN_CMD --cri-socket unix:///run/containerd/containerd.sock"
fi
if ! echo "$JOIN_CMD" | grep -q -- '--v='; then
  JOIN_CMD="$JOIN_CMD --v=5"
fi

# shellcheck disable=SC2086
sudo $JOIN_CMD

log "Worker joined. Verify on master: kubectl get nodes -o wide"

## based on: # based on: https://medium.com/@priyantha.getc/step-by-step-guide-to-creating-a-kubernetes-cluster-on-ubuntu-22-04-using-containerd-runtime-0ead53a8d273
