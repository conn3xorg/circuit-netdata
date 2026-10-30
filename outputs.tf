output "config_file" {
  description = "Path of netdata.conf on each host."
  value       = "${local.config_dir}/netdata.conf"
}

output "url" {
  description = "URL Netdata answers on, from each host itself when bind_to is the default."
  value       = "http://127.0.0.1:${var.port}"
}
