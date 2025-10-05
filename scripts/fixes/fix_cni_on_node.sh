#!/usr/bin/env bash
set -euo pipefail

CNI_VERSION="${CNI_VERSION:-v1.4.1}"
ARCH="${ARCH:-amd64}"

echo "==> Ensuring CNI binaries exist at /opt/cni/bin ..."
sudo mkdir -p /opt/cni/bin

if apt-cache show containernetworking-plugins >/dev/null 2>&1; then
  echo "==> Installing containernetworking-plugins via apt"
  sudo apt-get update -y
  sudo apt-get install -y containernetworking-plugins
  if [ -d /usr/lib/cni ]; then
    echo "==> Copying plugins from /usr/lib/cni to /opt/cni/bin"
    sudo cp -an /usr/lib/cni/* /opt/cni/bin/ || true
  fi
fi

if [ ! -x /opt/cni/bin/loopback ]; then
  echo "==> loopback plugin still missing; fetching from upstream ${CNI_VERSION}"
  curl -fsSL -o /tmp/cni.tgz "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
  sudo tar -xzf /tmp/cni.tgz -C /opt/cni/bin
fi

echo "==> Installed plugins:"
ls -1 /opt/cni/bin | sed 's/^/  - /'

if [ ! -x /opt/cni/bin/loopback ]; then
  echo "ERROR: loopback CNI still missing" >&2
  exit 1
fi

echo "==> Restarting kubelet"
sudo systemctl restart kubelet
echo "OK: CNI ready and kubelet restarted"
