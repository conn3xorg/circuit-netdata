variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "netdata_version" {
  type        = string
  default     = "2.12.2"
  description = "Netdata Agent release to install from Netdata's stable repository, such as \"2.12.2\". Raising it upgrades Netdata in place."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.netdata_version))
    error_message = "netdata_version must be a full release, such as \"2.12.2\"."
  }
}

variable "bind_to" {
  type        = string
  default     = "127.0.0.1"
  description = "Addresses Netdata's web server listens on, its [web] bind to, separated by spaces, such as \"127.0.0.1 ::1\" or \"*\" for every address. Children stream to this port too, so a parent needs an address they can reach."

  validation {
    condition     = can(regex("^[^\\n\\[\\]]+$", var.bind_to))
    error_message = "bind_to must be one line, such as \"127.0.0.1\", \"10.0.0.5 127.0.0.1\" or \"*\"."
  }
}

variable "port" {
  type        = number
  default     = 19999
  description = "Port Netdata's web server listens on, its [web] default port."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a port number from 1 to 65535."
  }
}

variable "db_mode" {
  type        = string
  default     = "dbengine"
  description = "Where Netdata keeps metrics, its [db] db: \"dbengine\" on disk, \"ram\" in memory only, or \"none\", which keeps nothing and suits a child that streams everything to a parent."

  validation {
    condition     = contains(["dbengine", "ram", "none"], var.db_mode)
    error_message = "db_mode must be dbengine, ram or none."
  }
}

variable "update_every" {
  type        = number
  default     = 1
  description = "Seconds between data collections, its [db] update every."

  validation {
    condition     = var.update_every >= 1 && floor(var.update_every) == var.update_every
    error_message = "update_every must be a whole number of seconds, 1 or more."
  }
}

variable "retention" {
  type = list(object({
    size = optional(string)
    time = optional(string)
  }))
  default     = []
  description = "dbengine storage tiers, from per-second tier 0 up, each with an optional size and time limit, such as [{ size = \"2GiB\", time = \"14d\" }, { time = \"3mo\" }, { time = \"2y\" }]. The list's length sets the number of tiers. When empty, Netdata's defaults."

  validation {
    condition     = length(var.retention) <= 5
    error_message = "Netdata has at most 5 storage tiers."
  }

  validation {
    condition     = alltrue([for t in var.retention : t.size == null || can(regex("^[0-9]+(B|KiB|MiB|GiB|TiB)?$", coalesce(t.size, "0")))])
    error_message = "A tier's size is a number with an optional unit, such as \"500MiB\" or \"2GiB\". 0 means no limit."
  }

  validation {
    condition     = alltrue([for t in var.retention : t.time == null || can(regex("^[0-9]+(s|m|h|d|w|mo|y)?$", coalesce(t.time, "0")))])
    error_message = "A tier's time is a number with an optional unit, such as \"14d\", \"3mo\" or \"2y\". 0 means no limit."
  }
}

variable "settings" {
  type        = map(map(string))
  default     = {}
  description = "More netdata.conf settings, by section, such as { ml = { enabled = \"no\" } }. Changing them restarts Netdata."

  validation {
    condition     = alltrue(flatten([for s, kv in var.settings : [for k, v in kv : can(regex("^[A-Za-z0-9_.:/ -]+$", s)) && can(regex("^[A-Za-z0-9_.:/ -]+$", k)) && !strcontains(v, "\n")]]))
    error_message = "Section names and keys use letters, digits, spaces and _ . : / -, such as \"plugin:proc\" or \"enable running new plugins\", and values can't contain line breaks."
  }

  validation {
    condition = alltrue(flatten([for s, kv in var.settings : [for k in keys(kv) : !(
      (s == "web" && contains(["bind to", "default port"], k)) ||
      (s == "db" && (contains(["db", "update every", "storage tiers"], k) || startswith(k, "dbengine tier ")))
    )]]))
    error_message = "settings can't set [web] bind to or default port, or [db] db, update every, storage tiers or tier retention. Use the circuit's own inputs."
  }
}

variable "collectors" {
  type        = map(string)
  default     = {}
  description = "go.d collector configurations, by module name, each the YAML for /etc/netdata/go.d/NAME.conf, such as { nginx = file(\"nginx.conf\") }. They land in state as plain text, so keep passwords out of them."

  validation {
    condition     = alltrue([for name in keys(var.collectors) : can(regex("^[a-z0-9_]+$", name))])
    error_message = "Collector names are go.d module names, such as nginx or postgres."
  }
}

variable "telemetry" {
  type        = bool
  default     = false
  description = "Send Netdata anonymous usage statistics. When false, the circuit writes /etc/netdata/.opt-out-from-anonymous-statistics before Netdata first starts."
}

variable "stream_destination" {
  type        = string
  default     = null
  description = "Parent or parents these hosts stream their metrics to, its [stream] destination, such as \"10.0.0.5:19999\", or several separated by spaces, tried in order. Add :SSL to a destination for TLS. When null, the hosts don't stream."

  validation {
    condition     = var.stream_destination == null || can(regex("^[^\\n\\[\\]]+$", coalesce(var.stream_destination, "-")))
    error_message = "stream_destination must be one line, such as \"10.0.0.5:19999\" or \"parent1:19999 parent2:19999\"."
  }
}

variable "stream_accept" {
  type        = bool
  default     = false
  description = "Make these hosts parents that accept streams from children presenting stream_api_key. Set bind_to so the children can reach them."
}

variable "stream_api_key" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Key children and their parent share, a UUID such as the output of uuidgen. Required when stream_destination or stream_accept is set. Pass it at run time with -var or TF_VAR_stream_api_key; it never reaches state or the plan."

  validation {
    condition     = (var.stream_destination == null && !var.stream_accept) || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", coalesce(var.stream_api_key, "-")))
    error_message = "Set stream_api_key to a UUID, such as the output of uuidgen, when stream_destination or stream_accept is set."
  }
}

variable "cloud_claim" {
  type        = bool
  default     = false
  description = "Connect the hosts to Netdata Cloud with cloud_token. Off by default: the Agent runs on its own and never talks to Netdata Cloud."
}

variable "cloud_token" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Claim token from your Netdata Cloud space. Required when cloud_claim is true. Pass it at run time with -var or TF_VAR_cloud_token; it never reaches state or the plan."

  validation {
    condition     = !var.cloud_claim || can(regex("^[A-Za-z0-9_-]+$", coalesce(var.cloud_token, "!")))
    error_message = "Set cloud_token to your space's claim token when cloud_claim is true."
  }
}

variable "cloud_rooms" {
  type        = list(string)
  default     = []
  description = "IDs of the Netdata Cloud rooms to add the hosts to. When empty, the space's default room."

  validation {
    condition     = alltrue([for r in var.cloud_rooms : can(regex("^[A-Za-z0-9-]+$", r))])
    error_message = "Each of cloud_rooms must be a room ID, letters, digits and -."
  }
}

variable "cloud_url" {
  type        = string
  default     = "https://app.netdata.cloud"
  description = "Netdata Cloud URL to claim with."

  validation {
    condition     = can(regex("^https?://[^\\s]+$", var.cloud_url))
    error_message = "cloud_url must be an http or https URL."
  }
}
