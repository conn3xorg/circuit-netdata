# circuit-netdata

A Conn3x circuit that installs the Netdata Agent from Netdata's own package repository, so every host collects thousands of metrics once a second and shows them on a dashboard at port 19999. Install it, wait a few seconds, and you can see which process ate the CPU at 03:12:07, not just that the five-minute average looked high.

What it doesn't do is phone home. Out of the box, the circuit opts the Agent out of Netdata's anonymous telemetry before it ever starts, binds the dashboard to `127.0.0.1` so only the host itself (or a proxy in front of it) can reach it, and leaves Netdata Cloud alone. Connecting to Cloud is one switch away if you want it. So is streaming: point a few children at a parent and you get one dashboard for all of them, with the parent keeping their history.

## Usage

```hcl
module "netdata" {
  source = "github.com/conn3xorg/circuit-netdata?ref=v0.1.0"

  hosts                = { web1 = "203.0.113.10", web2 = "203.0.113.11" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  retention = [
    { size = "2GiB", time = "14d" },
    { size = "1GiB", time = "3mo" },
    { size = "1GiB", time = "2y" },
  ]
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

The dashboard listens on `127.0.0.1:19999`. To look at it from your desk, open an SSH tunnel and browse to <http://localhost:19999>:

```sh
ssh -L 19999:127.0.0.1:19999 root@203.0.113.10
```

To serve it on the network, put a proxy with a login in front of it, such as [circuit-nginx](https://github.com/conn3xorg/circuit-nginx) or [circuit-caddy](https://github.com/conn3xorg/circuit-caddy), or set `bind_to` to an address people can reach. The Agent's dashboard has no login of its own.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry:

```hcl
hosts = {
  for name, d in digitalocean_droplet.web : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
  }
}
```

To try it on a pair of throwaway containers first, see [examples/local](examples/local). It sets up a parent and a child that streams to it.

### A parent and its children

Streaming sends a child's metrics to a parent as they're collected. The parent stores them and serves them on its own dashboard, so you can keep the children light and look in one place. Use one module for the parent and one for the children, with the same key:

```hcl
variable "stream_api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "netdata_parent" {
  source = "github.com/conn3xorg/circuit-netdata?ref=v0.1.0"

  hosts                = { mon1 = "10.0.0.5" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  bind_to        = "10.0.0.5 127.0.0.1"
  stream_accept  = true
  stream_api_key = var.stream_api_key
}

module "netdata_children" {
  source = "github.com/conn3xorg/circuit-netdata?ref=v0.1.0"

  hosts                = { web1 = "10.0.0.11", web2 = "10.0.0.12" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  stream_destination = "10.0.0.5:19999"
  stream_api_key     = var.stream_api_key
  db_mode            = "ram"
}
```

```sh
export TF_VAR_stream_api_key=$(uuidgen)   # once; keep it somewhere safe
conn3x apply
```

The key is a shared secret: anyone who has it can push metrics into the parent. It's an ephemeral variable, so it lands in `/etc/netdata/stream.conf` (mode `0640`, group `netdata`) and never in state or the plan. Pass the same key on every run. A different one rewrites the files and restarts Netdata, and children with an old key are turned away. Netdata itself prints the key in its own journal when a child starts, so treat `journalctl --namespace=netdata` on the children as sensitive too.

Children connect to the parent's web port, so the parent's `bind_to` must include an address they can reach, and its firewall must let them in. Streaming is plain TCP unless you add `:SSL` to the destination and give the parent a certificate, which this circuit doesn't do; on a network you don't trust, run it over [circuit-wireguard](https://github.com/conn3xorg/circuit-wireguard) or [circuit-tailscale](https://github.com/conn3xorg/circuit-tailscale).

### Netdata Cloud

The Agent works on its own, and by default the circuit never claims it. To connect hosts to a Netdata Cloud space, take the claim token and room IDs from the space's "Connect Nodes" page:

```hcl
cloud_claim = true
cloud_token = var.netdata_cloud_token   # an ephemeral variable, like the stream key
cloud_rooms = ["a1b2c3d4-..."]
```

The circuit writes them to `/etc/netdata/claim.conf` (mode `0640`, group `netdata`) and restarts Netdata, which claims the host on start. The token stays out of state and the plan. Setting `cloud_claim` back to `false` deletes the file, but the host stays claimed; remove it from the space in Netdata Cloud.

### Prometheus

Every Agent also serves its metrics in Prometheus format at `/api/v1/allmetrics?format=prometheus`. A parent serves its children's too, at `/host/CHILD/api/v1/allmetrics?format=prometheus`, or all of them at once with `format=prometheus_all_hosts`. A scrape job for it looks like this:

```yaml
- job_name: netdata
  metrics_path: /api/v1/allmetrics
  params:
    format: [prometheus]
  honor_labels: true
  static_configs:
    - targets: ["10.0.0.5:19999"]
```

[circuit-prometheus](https://github.com/conn3xorg/circuit-prometheus)'s `scrape_targets` scrapes `/metrics` only, so this job needs adding to its configuration by hand for now. If all you want is host metrics for Prometheus, [circuit-node-exporter](https://github.com/conn3xorg/circuit-node-exporter) is the smaller tool.

### Collectors

Netdata finds most services on its own: install nginx or PostgreSQL next to it and their charts appear. For a service it can't find, or one that needs a login, give the go.d collector's configuration in `collectors`, by module name:

```hcl
collectors = {
  nginx = <<-EOT
    jobs:
      - name: local
        url: http://127.0.0.1/basic_status
  EOT
}
```

Each lands in `/etc/netdata/go.d/NAME.conf`. They're kept in state as plain text, so don't put passwords in them; have the service accept Netdata's local connection instead, or write that one file another way.

## What it does

On each host, in order:

1. Adds Netdata's stable repository, `repository.netdata.cloud/repos/stable`, with Netdata's signing key from [files/netdata.asc](files/netdata.asc). That key, `6E155DC153906B73765A74A99DD4A74CECFA8F4F`, expires on 14 March 2035. On Debian and Ubuntu it also pins every `netdata` package to `netdata_version` in `/etc/apt/preferences.d/netdata`, since each plugin package needs exactly its own netdata version.
2. Creates `/etc/netdata` and writes the telemetry opt-out file and `netdata.conf` there, before the package. That way the Agent's first start already binds to `bind_to` and sends no telemetry. Both the deb and rpm packages keep a `netdata.conf` that's already there; the one they ship is left next to it as `netdata.conf.dpkg-dist` or `netdata.conf.rpmnew`, and is only comments.
3. Installs `netdata` at `netdata_version`, which pulls in the dashboard and Netdata's default plugins. A higher version upgrades it in place.
4. Writes `stream.conf` when streaming is on, `claim.conf` when `cloud_claim` is on, and one file in `go.d` per collector.
5. Starts Netdata now and at boot, and restarts it when any of those files or the package changes.

`netdata.conf` gets `[web] bind to` and `default port`, `[db] db` and `update every`, and one pair of retention lines per tier in `retention`, plus anything in `settings`. Everything else keeps Netdata's defaults; `netdatacli dumpconfig` on a host shows the lot.

The anonymous telemetry opt-out is the file `/etc/netdata/.opt-out-from-anonymous-statistics`, which is what [Netdata's docs](https://learn.netdata.cloud/docs/netdata-agent/configuration/anonymous-telemetry-events) name as the way to turn it off for both the Agent and its dashboard. Set `telemetry = true` and the circuit deletes the file.

The circuit installs from the repository directly rather than through Netdata's `kickstart.sh`, and doesn't install the `netdata-repo` package or turn on `netdata-updater`. Updates come when you raise `netdata_version`.

### What it doesn't do

- It doesn't open firewall ports. For a parent, let the children reach its port with [circuit-firewall](https://github.com/conn3xorg/circuit-firewall).
- It doesn't set up TLS on the dashboard or between parent and child.
- It doesn't write alert or notification settings (`health.d`, `health_alarm_notify.conf`).
- Deleting the module leaves Netdata installed and running with the last files.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `netdata_version` | string | `"2.12.2"` | Netdata Agent release to install. Raising it upgrades in place. |
| `bind_to` | string | `"127.0.0.1"` | `[web] bind to`: addresses the dashboard and API listen on, separated by spaces, or `"*"` for all. A parent needs one its children can reach. |
| `port` | number | `19999` | `[web] default port`. |
| `db_mode` | string | `"dbengine"` | `[db] db`: `dbengine` keeps metrics on disk, `ram` in memory only, and `none` keeps nothing, for a child that streams everything. |
| `update_every` | number | `1` | `[db] update every`: seconds between collections. |
| `retention` | list(object) | `[]` | dbengine storage tiers from tier 0 (per second) up, each with an optional `size`, such as `"2GiB"`, and `time`, such as `"14d"`. The list's length sets `storage tiers`. When empty, Netdata's defaults: three tiers of 1 GiB, kept 14 days, 3 months and 2 years. |
| `settings` | map(map(string)) | `{}` | More `netdata.conf` settings, by section, such as `{ ml = { enabled = "no" } }`. Can't set what the inputs above set. |
| `collectors` | map(string) | `{}` | go.d collector configurations, by module name, each the YAML for `/etc/netdata/go.d/NAME.conf`. Stored in state as plain text. |
| `telemetry` | bool | `false` | Send Netdata anonymous usage statistics. When false, the opt-out file is in place before the first start. |
| `stream_destination` | string | `null` | Parent, or parents separated by spaces, these hosts stream to, such as `"10.0.0.5:19999"`. When null, they don't stream. |
| `stream_accept` | bool | `false` | Make these hosts parents that accept children presenting `stream_api_key`. |
| `stream_api_key` | string, ephemeral, sensitive | `null` | Key shared by parent and children, a UUID such as `uuidgen` prints. Required when streaming. Never stored in state or the plan. |
| `cloud_claim` | bool | `false` | Connect the hosts to Netdata Cloud. |
| `cloud_token` | string, ephemeral, sensitive | `null` | Claim token from your Netdata Cloud space. Required when `cloud_claim` is true. Never stored in state or the plan. |
| `cloud_rooms` | list(string) | `[]` | Netdata Cloud room IDs to add the hosts to. |
| `cloud_url` | string | `"https://app.netdata.cloud"` | Netdata Cloud URL to claim with. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of `netdata.conf` on each host, `/etc/netdata/netdata.conf`. |
| `url` | URL the dashboard answers on from the host itself with the default `bind_to`, `http://127.0.0.1:19999`. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, which must reach `repository.netdata.cloud`.

The circuit picks Netdata's repository by distribution and release, and knows the ones Netdata publishes stable packages for: Debian 12 and 13, Ubuntu 22.04, 24.04 and 26.04, Rocky Linux, AlmaLinux, RHEL and Fedora, on amd64 and arm64. The ones it was tried on are under [Tested on](#tested-on).

Fedora 45 isn't supported yet: on 29 October 2026, Netdata's stable repository had packages for Fedora 43 and 44 but not 45, so an apply there fails at the package. It should work once Netdata publishes them, with no change here.

## Tested on

Rocky Linux 10, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local), a parent and a child container, to each on amd64. It checks that the second plan has no changes; that the child runs Netdata 2.12.2, answers `/api/v1/info` on `127.0.0.1:19999` and returns per-second `system.cpu` points from `/api/v1/data`; that the opt-out file is there and the Agent isn't claimed; that the parent can't reach the child's port; and that the child shows up in the parent's `/api/v2/nodes` with its own data.

The same checks passed by hand in arm64 containers on the same three, and on Fedora 44. On Ubuntu 24.04, a child installed at 2.12.1 came up with every plugin on 2.12.1, and raising `netdata_version` to 2.12.2 upgraded them all in place. A claim with a made-up token and an unreachable `cloud_url` wrote `claim.conf` with mode `0640` and group `netdata`, kept the token out of state, and setting `cloud_claim = false` removed the file again; claiming against Netdata Cloud itself wasn't tried.

It was also applied to an Ubuntu 24.04 droplet as a parent, bound to its private address and `127.0.0.1`, and a Rocky Linux 10 droplet with SELinux enforcing as a child with `db_mode = "ram"`, streaming over the private network. The child appeared on the parent with its data, neither answered on its public address, and the audit log had no denials. After rebooting both, the plan had no changes and the same checks passed.

## License

MPL-2.0. See [LICENSE](LICENSE). Netdata itself is GPL-3.0-or-later.
