#!/usr/bin/env bash
set -euo pipefail

# ===== Config you may tweak =====
K8S_MAJOR_MINOR="1.28"
K8S_VERSION_PIN="${K8S_MAJOR_MINOR}.*"      # pin family
POD_CIDR="10.244.0.0/16"                    # Weave is fine with this
USE_WEAVE="true"                            # set to "false" if you want to apply your own CNI later
# =================================

log() { printf '\n\033[1;32m[MASTER]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*"; }

# 0) Basic sanity + optional firewall disable (dev only)
log "Updating & basic tools"
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl gpg gnupg2 lsb-release software-properties-common net-tools conntrack

if command -v ufw >/dev/null 2>&1; then
  warn "Disabling UFW (DEV ONLY). In production, open only required ports."
  sudo ufw disable || true
fi

# 1) Time sync
log "Ensuring systemd-timesyncd is enabled"
sudo apt install -y systemd-timesyncd
sudo timedatectl set-ntp true

# 2) Swap off (and keep it off)
log "Disabling swap"
sudo swapoff -a
sudo sed -i.bak -r 's/(.+[[:space:]]swap[[:space:]].+)/#\1/' /etc/fstab
free -m | awk '/Swap/ {print "Swap now:", $0}'

# 3) Kernel modules + sysctl
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

# 4) Install containerd from Docker repo
log "Installing containerd.io"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
 | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
 | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update -y
sudo apt install -y containerd.io cri-tools

# 5) Configure containerd (SystemdCgroup=true, disabled_plugins=[])
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

# 6) Add ONLY Kubernetes v1.28 repo + pin
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

# 7) Clean any previous failed inits (safe on fresh host)
log "Cleaning any previous kubeadm state"
sudo systemctl stop kubelet || true
sudo kubeadm reset -f || true
sudo umount -R /var/lib/kubelet 2>/dev/null || true
sudo rm -rf /var/lib/etcd /var/lib/kubelet/* /etc/cni/net.d /var/lib/cni || true

# 8) Enable kubelet (it'll wait for join/init)
sudo systemctl enable --now kubelet

# 9) Init control-plane (explicit CRI socket)
log "Initializing control-plane"
sudo kubeadm init \
  --kubernetes-version "v${K8S_MAJOR_MINOR}.15" \
  --cri-socket unix:///run/containerd/containerd.sock \
  --pod-network-cidr "${POD_CIDR}" \
  --v=5

# 10) Kubeconfig for current user
log "Setting kubeconfig for current user"
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"(id -g)" "$HOME/.kube/config"

# 11) CNI (Weave, per the guide)
if [ "${USE_WEAVE}" = "true" ]; then
  log "Applying Weave Net CNI"
  kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
else
  warn "Skipping CNI apply (USE_WEAVE=false). Apply your CNI before joining workers."
fi

# 12) Show join command and also save it to a file
log "Generating worker join command"
JOIN_CMD="$(kubeadm token create --print-join-command)"
echo "${JOIN_CMD} --cri-socket unix:///run/containerd/containerd.sock" | tee "$HOME/join-worker.sh"
chmod +x "$HOME/join-worker.sh"

log "Done. Your join command is saved at: $HOME/join-worker.sh"
log "Verify node + pods:"
echo "  kubectl get nodes -o wide"
echo "  kubectl -n kube-system get pods -o wide | egrep -i 'weave|calico|cni'"

## based on: # based on: https://medium.com/@priyantha.getc/step-by-step-guide-to-creating-a-kubernetes-cluster-on-ubuntu-22-04-using-containerd-runtime-0ead53a8d273
