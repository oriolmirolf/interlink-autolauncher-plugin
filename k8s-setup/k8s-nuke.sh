#!/usr/bin/env bash
set -euo pipefail

# === Options ===
: "${PURGE_CONTAINERD:=false}"   # set true to purge containerd + data
: "${PURGE_MICROK8S:=true}"      # remove microk8s if present
: "${FLUSH_IPTABLES:=true}"      # flush iptables/nftables rules

log()  { printf '\033[1;31m[NUKE]\033[0m %s\n' "$*"; }
info() { printf '  - %s\n' "$*"; }

log "Stopping kubelet/etcd/microk8s if present"
sudo systemctl stop kubelet 2>/dev/null || true
sudo systemctl stop etcd 2>/dev/null || true
if $PURGE_MICROK8S && command -v snap >/dev/null 2>&1; then
  snap list 2>/dev/null | grep -q '^microk8s' && sudo snap stop microk8s || true
fi

log "kubeadm reset (safe even if not initialized)"
sudo kubeadm reset -f 2>/dev/null || true

log "Unmounting any kubelet mounts"
# Unmount deepest first
while mount | awk '{print $3}' | grep -q '^/var/lib/kubelet'; do
  for m in $(mount | awk '/\/var\/lib\/kubelet/ {print $3}' | sort -r); do
    sudo umount -f "$m" 2>/dev/null || true
  done
done

log "Removing Kubernetes state & configs"
sudo rm -rf \
  /etc/kubernetes \
  /var/lib/kubelet \
  /var/lib/etcd \
  /var/run/kubernetes \
  /etc/cni/net.d \
  /var/lib/cni \
  /opt/cni/bin/*-weave* /opt/cni/bin/*calico* 2>/dev/null || true

# User kubeconfigs
sudo rm -f $HOME/.kube/config 2>/dev/null || true
sudo rm -f /root/.kube/config 2>/dev/null || true

log "Purging Kubernetes packages (kubeadm/kubelet/kubectl/kubernetes-cni)"
sudo apt-mark unhold kubeadm kubelet kubectl 2>/dev/null || true
sudo apt-get -y purge kubeadm kubelet kubectl kubernetes-cni 2>/dev/null || true
sudo apt-get -y autoremove --purge 2>/dev/null || true

if $PURGE_MICROK8S && command -v snap >/dev/null 2>&1; then
  log "Removing MicroK8s (snap), if installed"
  snap list 2>/dev/null | grep -q '^microk8s' && sudo snap remove microk8s || true
  snap list 2>/dev/null | grep -q '^kubectl'  && sudo snap remove kubectl  || true
fi

log "Removing stray kubeadm binaries ahead of /usr/bin"
for p in /usr/local/bin/kubeadm /bin/kubeadm; do
  if [ -x "$p" ]; then
    info "Deleting $p"
    sudo rm -f "$p" || true
  fi
done

log "Removing Kubernetes APT repos & keys"
sudo rm -f /etc/apt/sources.list.d/*kubernetes* /etc/apt/sources.list.d/*pkgs.k8s.io* || true
sudo rm -f /etc/apt/preferences.d/kubernetes 2>/dev/null || true
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true

if $FLUSH_IPTABLES; then
  log "Flushing iptables/nftables rules (may disrupt other networking)"
  sudo iptables -F || true
  sudo iptables -t nat -F || true
  sudo iptables -t mangle -F || true
  sudo iptables -X || true
  sudo ip6tables -F 2>/dev/null || true
  sudo ip6tables -t nat -F 2>/dev/null || true
fi

if $PURGE_CONTAINERD; then
  log "Purging containerd + CRI tools and data"
  sudo systemctl stop containerd 2>/dev/null || true
  sudo apt-get -y purge containerd.io cri-tools 2>/dev/null || true
  sudo rm -rf /etc/containerd /var/lib/containerd /var/run/containerd /etc/crictl.yaml || true
  # Also remove Docker repo/key if added solely for containerd
  sudo rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true
  sudo rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null || true
fi

log "Cleaning APT caches"
sudo apt-get update -y
sudo apt-get -y autoremove --purge 2>/dev/null || true
sudo apt-get -y clean 2>/dev/null || true

log "Done. Host is clean of Kubernetes state."
info "If you plan to reinstall: reboot is optional but recommended."
