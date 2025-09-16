#!/usr/bin/env bash
set -euo pipefail

# ---- EDIT THESE ----
export PUBLIC_IP="192.168.0.98"
export API_PORT="30443"
export IL_VERSION="$(curl -s https://api.github.com/repos/interlink-hq/interlink/releases/latest | jq -r .name)"
export KUBELET_NODE_NAME="autolauncher-edge"
# --------------------

# Installer
if [ ! -x "$HOME/.interlink/interlink-installer" ]; then
  wget -O "$HOME/.interlink/interlink-installer" \
    "https://github.com/interlink-hq/interLink/releases/download/${IL_VERSION}/interlink-installer_Linux_x86_64"
  chmod +x "$HOME/.interlink/interlink-installer"
fi

# Minimal mTLS config
cat > "$HOME/.interlink/installer.yaml" <<EOF
interlink_ip: ${PUBLIC_IP}
interlink_port: ${API_PORT}
interlink_version: ${IL_VERSION}
kubelet_node_name: ${KUBELET_NODE_NAME}
kubernetes_namespace: interlink
node_limits:
  cpu: "1000"
  memory: 25600
  pods: "100"
mtls:
  enabled: true
insecure_http: true
EOF

$HOME/.interlink/interlink-installer --config $HOME/.interlink/installer.yaml --output-dir $HOME/.interlink/manifests/

chmod +x $HOME/.interlink/manifests/interlink-remote.sh
$HOME/.interlink/manifests/interlink-remote.sh install
$HOME/.interlink/manifests/interlink-remote.sh start

echo "mTLS remote components installed. Logs: $HOME/.interlink/logs"
