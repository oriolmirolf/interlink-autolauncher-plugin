#!/bin/bash
set -eux

# Run pre-reqs
bash ./common.sh

# Wait for join token input (edit or copy in runtime)
read -p "Paste the kubeadm join command here: " JOIN_CMD
$JOIN_CMD
