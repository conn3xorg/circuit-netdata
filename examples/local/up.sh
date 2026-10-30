#!/usr/bin/env sh
# Starts two throwaway hosts that Conn3x can configure, a Netdata parent on
# 127.0.0.1:$PORT (default 2301) and a child on the next port, with a fresh
# SSH key and their host keys in ./known_hosts. They share a Podman network,
# so the child reaches the parent by its container name.
# CONTAINERFILE picks another image, such as one of Conn3x's test images.
# Needs Podman, since the hosts run systemd. The containers are privileged
# because Netdata's unit sets up its own mount namespace for its sandbox.
# Rootful Podman is simplest:
# CONTAINER_CONNECTION=podman-machine-default-root on a Mac, or
# PODMAN="sudo podman" on Linux.
set -eu
cd "$(dirname "$0")"
port=${PORT:-2301}
child_port=$((port + 1))
containerfile=${CONTAINERFILE:-Containerfile}
name=${NAME:-circuit-netdata}

podman=${PODMAN:-podman}
[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "$name" -f id_ed25519
$podman build -q -f "$containerfile" -t "$name" "$(dirname "$containerfile")" >/dev/null
$podman network exists "$name" || $podman network create "$name" >/dev/null
: > known_hosts

for role in parent child; do
  p=$port
  [ "$role" = child ] && p=$child_port
  $podman rm -f -v "$name-$role" >/dev/null 2>&1 || true
  $podman run -d --name "$name-$role" --hostname "$name-$role" --network "$name" \
    --systemd=always --privileged -p "127.0.0.1:$p:22" "$name" >/dev/null
  $podman exec -i "$name-$role" sh -c 'cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' < id_ed25519.pub
  $podman exec "$name-$role" timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true

  ok=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ssh-keyscan -p "$p" 127.0.0.1 > known_hosts.$role 2>/dev/null && [ -s known_hosts.$role ]; then
      ok=1
      break
    fi
    sleep 1
  done
  [ -n "$ok" ] || { echo "The $role container started, but SSH didn't answer on 127.0.0.1:$p." >&2; exit 1; }
  cat known_hosts.$role >> known_hosts && rm -f known_hosts.$role
done

echo "Ready on 127.0.0.1:$port (parent) and 127.0.0.1:$child_port (child). Now run:"
echo "  export TF_VAR_stream_api_key=\$(uuidgen)"
echo "  conn3x init && conn3x apply -var port=$port -var child_port=$child_port"
