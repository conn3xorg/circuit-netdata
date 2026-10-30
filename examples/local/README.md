# Local example

Applies circuit-netdata to two throwaway Rocky Linux 10 containers with systemd: a parent that keeps a week of per-second data and listens on its network, and a child that listens on `127.0.0.1` only and streams everything to the parent. You need Conn3x and Podman.

Netdata's systemd unit sets up a mount namespace for its sandbox, so the containers run privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
export TF_VAR_stream_api_key=$(uuidgen)
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes`, as long as `TF_VAR_stream_api_key` is the same as for the apply. To see the child on the parent:

```sh
ssh -p 2301 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  curl -s http://127.0.0.1:19999/api/v2/nodes
```

To open the parent's dashboard in your browser, forward its port and browse to <http://localhost:19999>. The child shows up in the node list:

```sh
ssh -p 2301 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 19999:127.0.0.1:19999 root@127.0.0.1
```

`up.sh` listens on `127.0.0.1:2301` for the parent and `127.0.0.1:2302` for the child. Set `PORT` to move both, and pass the same ports to Conn3x with `-var port=PORT -var child_port=PORT+1`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the containers, their network and volumes, the key and the state.
