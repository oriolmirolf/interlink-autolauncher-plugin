# edge-30-interlink-remote-noauth.sh
set -euo pipefail

# Versions
IL_VERSION="$(curl -s https://api.github.com/repos/interlink-hq/interlink/releases/latest | jq -r .name)"

mkdir -p $HOME/.interlink/{logs,manifests}
[ -x "$HOME/.interlink/interlink-installer" ] || {
  wget -O "$HOME/.interlink/interlink-installer" \
    "https://github.com/interlink-hq/interLink/releases/download/${IL_VERSION}/interlink-installer_Linux_x86_64"
  chmod +x "$HOME/.interlink/interlink-installer"
}

cat > "$HOME/.interlink/installer.yaml" <<EOF
interlink_ip: 0.0.0.0
interlink_port: 30433
interlink_version: "${IL_VERSION}"
kubelet_node_name: autolauncher-edge
kubernetes_namespace: interlink
node_limits: { cpu: "2000", memory: "8192", pods: "30" }
oauth: {}
insecure_http: true
EOF

$HOME/.interlink/interlink-installer --config "$HOME/.interlink/installer.yaml" --output-dir "$HOME/.interlink/manifests/"
chmod +x $HOME/.interlink/manifests/interlink-remote.sh
$HOME/.interlink/manifests/interlink-remote.sh install
$HOME/.interlink/manifests/interlink-remote.sh start

sudo apt-get install -y socat
# Bridge UNIX socket to TCP (if the API is only on unix socket)
cat <<'UNIT' | sudo tee /etc/systemd/system/interlink-api-bridge.service >/dev/null
[Unit]
Description=Expose interLink UNIX socket on TCP 30433
After=network-online.target
Wants=network-online.target

[Service]
User=ubuntu
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do [ -S /home/ubuntu/.interlink/.interlink.sock ] && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/bin/socat TCP-LISTEN:30433,fork,bind=0.0.0.0 UNIX-CONNECT:/home/ubuntu/.interlink/.interlink.sock
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now interlink-api-bridge
sleep 1
curl -sS -v http://192.168.0.98:30433/pinglink || true
