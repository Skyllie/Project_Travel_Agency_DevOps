output "url" {
  description = "Address of the load balancer on the Docker host"
  value       = "http://localhost:${var.lb_port}/"
}

output "app_servers" {
  description = "Application servers and their addresses"
  value       = { for n in local.nodes : n.name => n.ip }
}

output "lb_algorithm" {
  description = "Load-balancing algorithm in use"
  value       = var.lb_algorithm
}

output "app_image" {
  description = "Application image the servers run"
  value       = var.app_image
}
