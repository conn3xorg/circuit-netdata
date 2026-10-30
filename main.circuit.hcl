# Facts give each host's distribution and release, which pick Netdata's
# apt suite or yum repository.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  # Netdata publishes one flat apt repository per release, named by its
  # codename, and one yum repository per Red Hat family release.
  codename = { "22.04" = "jammy", "24.04" = "noble", "26.04" = "resolute", "12" = "bookworm", "13" = "trixie" }
  base     = "https://repository.netdata.cloud/repos/stable"

  hosts = {
    for name, f in data.conn3x_host.facts : name => {
      family = f.os_family
      url    = f.os_family == "debian" ? "${local.base}/${f.os_id}/" : "${local.base}/${f.os_id == "fedora" ? "fedora" : "el"}/$releasever/$basearch/"
      suites = f.os_family == "debian" ? ["${local.codename[f.os_version]}/"] : null
    }
  }

  config_dir = "/etc/netdata"

  # The circuit's own settings win over the same keys in var.settings,
  # which a validation turns away anyway.
  own = {
    web = {
      "bind to"      = var.bind_to
      "default port" = tostring(var.port)
    }
    db = merge(
      {
        "db"           = var.db_mode
        "update every" = tostring(var.update_every)
      },
      length(var.retention) == 0 ? {} : { "storage tiers" = tostring(length(var.retention)) },
      merge([for i, t in var.retention : merge(
        t.size == null ? {} : { "dbengine tier ${i} retention size" = t.size },
        t.time == null ? {} : { "dbengine tier ${i} retention time" = t.time },
      )]...),
    )
  }
  sections = merge(var.settings, { for s, kv in local.own : s => merge(lookup(var.settings, s, {}), kv) })
  netdata_conf = join("\n", concat(
    ["# Written by Conn3x. Changes here are overwritten on the next apply.\n"],
    [for s, kv in local.sections : join("", concat(["[${s}]\n"], [for k, v in kv : "    ${k} = ${v}\n"]))],
  ))

  # A child sends to stream_destination; a parent accepts any child that
  # presents the same key. One file can do both, for a parent that streams
  # on to another parent.
  streaming = var.stream_destination != null || var.stream_accept
  stream_conf = join("\n", compact([
    var.stream_destination == null ? "" : "[stream]\n    enabled = yes\n    destination = ${var.stream_destination}\n    api key = ${coalesce(var.stream_api_key, "-")}\n",
    var.stream_accept ? "[${coalesce(var.stream_api_key, "-")}]\n    enabled = yes\n" : "",
  ]))

  claim_conf = join("", compact([
    "[global]\n",
    "    url = ${var.cloud_url}\n",
    "    token = ${coalesce(var.cloud_token, "-")}\n",
    length(var.cloud_rooms) == 0 ? "" : "    rooms = ${join(",", var.cloud_rooms)}\n",
  ]))
}

# Every plugin package depends on exactly its own netdata version, and apt
# doesn't look past the newest plugin when an older netdata is asked for.
# The pin keeps the whole set on netdata_version.
circuit "apt" {
  hosts = { for name, h in var.hosts : name => h if local.hosts[name].family == "debian" }

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "pin" {
    file {
      path    = "/etc/apt/preferences.d/netdata"
      content = "Package: netdata netdata-*\nPin: version ${var.netdata_version}\nPin-Priority: 1001\n"
    }
  }
}

circuit "netdata" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Netdata's signing key expires on 14 March 2035.
  step "repo" {
    repository {
      name   = "netdata"
      url    = local.hosts[each.key].url
      key    = file("${path.module}/files/netdata.asc")
      suites = local.hosts[each.key].suites
    }
  }

  # The opt-out file and netdata.conf go in before the package, so the
  # first start already listens only on bind_to and sends no telemetry.
  # Both packages keep a netdata.conf that's already there.
  step "config_dir" {
    directory {
      path = local.config_dir
    }
  }

  step "telemetry_opt_out" {
    for_each = var.telemetry ? toset([]) : toset(["opt-out"])
    file {
      path      = "${local.config_dir}/.opt-out-from-anonymous-statistics"
      content   = ""
      on_remove = "delete"
    }
  }

  step "config" {
    file {
      path    = "${local.config_dir}/netdata.conf"
      content = local.netdata_conf
    }
    notify = [handler.restart]
  }

  step "package" {
    depends_on = [conn3x_file.apt__pin]
    package {
      name    = "netdata"
      version = var.netdata_version
    }
    notify = [handler.restart]
  }

  # The API key is a shared secret, so the file lands on the host without
  # passing through state or the plan.
  step "stream" {
    for_each = local.streaming ? toset(["stream"]) : toset([])
    file {
      path       = "${local.config_dir}/stream.conf"
      content_wo = local.stream_conf
      group      = "netdata"
      mode       = "0640"
      on_remove  = "delete"
    }
    notify = [handler.restart]
  }

  step "claim" {
    for_each = var.cloud_claim ? toset(["claim"]) : toset([])
    file {
      path       = "${local.config_dir}/claim.conf"
      content_wo = local.claim_conf
      group      = "netdata"
      mode       = "0640"
      on_remove  = "delete"
    }
    notify = [handler.restart]
  }

  step "collectors" {
    for_each = var.collectors
    file {
      path      = "${local.config_dir}/go.d/${item.key}.conf"
      content   = item.value
      group     = "netdata"
      mode      = "0640"
      on_remove = "delete"
    }
    notify = [handler.restart]
  }

  step "running" {
    service {
      name    = "netdata"
      state   = "started"
      enabled = true
    }
  }

  handler "restart" {
    service {
      name = "netdata"
    }
  }
}
