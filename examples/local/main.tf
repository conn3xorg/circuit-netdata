variable "port" {
  type    = number
  default = 2301
}

variable "child_port" {
  type    = number
  default = 2302
}

variable "stream_api_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

# The parent listens on every address so the child container can reach
# it on the Podman network. It keeps a week of per-second data.
module "parent" {
  source = "../.."

  hosts                = { parent = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  bind_to        = "*"
  stream_accept  = true
  stream_api_key = var.stream_api_key

  retention = [
    { size = "1GiB", time = "7d" },
    { size = "512MiB", time = "3mo" },
  ]

  settings = {
    ml = { enabled = "no" }
  }
}

# The child keeps the default 127.0.0.1 and streams everything to the
# parent by its container name.
module "child" {
  source = "../.."

  hosts                = { child = "127.0.0.1" }
  ssh_port             = var.child_port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  stream_destination = "circuit-netdata-parent:19999"
  stream_api_key     = var.stream_api_key

  collectors = {
    ping = <<-EOT
      jobs:
        - name: loopback
          hosts:
            - 127.0.0.1
    EOT
  }
}
