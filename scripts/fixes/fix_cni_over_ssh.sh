#!/usr/bin/env bash
set -euo pipefail
if [ $# -lt 2 ]; then
  echo "Usage: $0 <node-ip> <ssh-user> [ssh-key]" >&2
  exit 1
fi
NODE="$1"; USER="$2"; KEY="${3:-}"

SCP="scp"; SSH="ssh"
if [ -n "$KEY" ]; then
  SCP="$SCP -i $KEY"
  SSH="$SSH -i $KEY"
fi

$SCP scripts/fixes/fix_cni_on_node.sh "${USER}@${NODE}:/tmp/fix_cni_on_node.sh"
$SSH "${USER}@${NODE}" "bash /tmp/fix_cni_on_node.sh"
