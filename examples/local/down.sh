#!/usr/bin/env sh
# Removes the containers, their network and everything up.sh and Conn3x
# created here.
set -eu
cd "$(dirname "$0")"
name=${NAME:-circuit-netdata}
podman=${PODMAN:-podman}
$podman rm -f -v "$name-parent" "$name-child" >/dev/null 2>&1 || true
$podman network rm "$name" >/dev/null 2>&1 || true
rm -rf id_ed25519 id_ed25519.pub known_hosts known_hosts.* .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
echo "Removed."
