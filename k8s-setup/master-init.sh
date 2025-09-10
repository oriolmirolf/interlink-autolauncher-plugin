#!/bin/bash
set -eux

# Call the common pre-reqs
bash ./common.sh

# Init master
kubeadm init --config=kubeadm-config.yaml --upload-certs | tee kubeadm-init.out

# Set up kubectl access
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 📡 Install network plugin (Flannel)
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
