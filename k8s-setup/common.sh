#!/bin/bash
set -eux

# 🧹 Remove previous installs (Kubernetes, CRI, etc.)
kubeadm reset -f || true
apt-get purge -y kubeadm kubelet kubectl containerd docker.io || true
apt-get autoremove -y
rm -rf ~/.kube /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni

# 🔧 Kernel modules and sysctl
modprobe overlay
modprobe br_netfilter

tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

# 📦 Install dependencies
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# 🔒 Add Kubernetes APT repo
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl containerd
apt-mark hold kubelet kubeadm kubectl

# 🛠️ Containerd config
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null

# Patch for cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable kubelet containerd
