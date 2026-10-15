variable "docker_host" {
  description = "Docker daemon that Terraform manages"
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "project" {
  description = "Prefix for the names of containers, the network and the volume"
  type        = string
  default     = "travelagency-tf"
}

variable "subnet" {
  description = "Subnet of the Docker network; the containers get fixed addresses in it"
  type        = string
  default     = "172.31.0.0/24"
}

variable "app_image" {
  description = "Application image, built before apply: docker build -t travelagency:local ."
  type        = string
  default     = "travelagency:local"
}

variable "app_replicas" {
  description = "Number of application servers behind the load balancer"
  type        = number
  default     = 3

  validation {
    condition     = var.app_replicas >= 1 && var.app_replicas <= 5
    error_message = "app_replicas must be from 1 to 5."
  }
}

variable "java_opts" {
  description = "JVM options of each Tomcat"
  type        = string
  default     = "-Xmx320m"
}

variable "lb_algorithm" {
  description = "Nginx load-balancing algorithm"
  type        = string
  default     = "round_robin"

  validation {
    condition     = contains(["round_robin", "weighted", "least_conn", "ip_hash", "hash", "random", "backup"], var.lb_algorithm)
    error_message = "lb_algorithm must be one of: round_robin, weighted, least_conn, ip_hash, hash, random, backup."
  }
}

variable "lb_sticky" {
  description = "Sticky sessions by the Tomcat jvmRoute in JSESSIONID"
  type        = bool
  default     = true
}

variable "lb_port" {
  description = "Port of the load balancer on the Docker host"
  type        = number
  default     = 80
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "travelagency"
}

variable "db_user" {
  description = "Database user of the application"
  type        = string
  default     = "travel"
}

variable "db_password" {
  description = "Password of the database user"
  type        = string
  sensitive   = true
}

variable "mysql_root_password" {
  description = "Password of the MySQL root user"
  type        = string
  sensitive   = true
}
