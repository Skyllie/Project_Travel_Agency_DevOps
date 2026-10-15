# TravelAgency as code: network, volume, MySQL, N application servers and the Nginx
# load balancer — the same stack as docker-compose.yml in the docker-load-balancer branch.

locals {
  db_ip = cidrhost(var.subnet, 10)
  lb_ip = cidrhost(var.subnet, 20)

  # app1 .11, app2 .12, ...
  nodes = [for i in range(var.app_replicas) : {
    name = "app${i + 1}"
    ip   = cidrhost(var.subnet, 11 + i)
  }]

  # Extra parameters of each server in the pool, depending on the algorithm
  #   weighted: app1 weight 3, the others 1;  backup: the last server is a backup
  pool = [for i, n in local.nodes : {
    name = n.name
    ip   = n.ip
    params = join(" ", compact([
      var.lb_algorithm == "weighted" ? (i == 0 ? "weight=3" : "weight=1") : "",
      (var.lb_algorithm == "backup" && i == length(local.nodes) - 1 && length(local.nodes) > 1) ? "backup" : "max_fails=3 fail_timeout=10s",
    ]))
  }]

  algorithm_directive = {
    round_robin = ""
    weighted    = ""
    least_conn  = "least_conn;"
    ip_hash     = "ip_hash;"
    hash        = "hash $request_uri consistent;"
    random      = "random two least_conn;"
    backup      = ""
  }

  nginx_conf = templatefile("${path.module}/templates/nginx.conf.tftpl", {
    algorithm = var.lb_algorithm
    directive = local.algorithm_directive[var.lb_algorithm]
    sticky    = var.lb_sticky
    nodes     = local.nodes
    pool      = local.pool
  })

  # Environment shared by all application servers; the database is found by its container name
  app_env = [
    "DB_HOST=${docker_container.db.name}",
    "DB_NAME=${var.db_name}",
    "DB_TRAVELAGENCY_USER=${var.db_user}",
    "DB_TRAVELAGENCY_PASSWORD=${var.db_password}",
    "HBM2DDL_AUTO=update",
  ]

  # Same check as the HEALTHCHECK in the Dockerfile
  app_healthcheck = {
    test         = ["CMD-SHELL", "curl -fsS -o /dev/null http://localhost:8080/form-login || exit 1"]
    interval     = "10s"
    timeout      = "5s"
    start_period = "50s"
    retries      = 12
  }
}

# ---- Network and storage

resource "docker_network" "lb_net" {
  name = "${var.project}-net"

  ipam_config {
    subnet = var.subnet
  }
}

resource "docker_volume" "db_data" {
  name = "${var.project}-db-data"
}

# ---- Images

resource "docker_image" "mysql" {
  name         = "mysql:8.4"
  keep_locally = true
}

resource "docker_image" "nginx" {
  name         = "nginx:1.28-alpine"
  keep_locally = true
}

# Built outside Terraform (docker build, or the Jenkins pipeline); Terraform only reads it
data "docker_image" "app" {
  name = var.app_image
}

# ---- Database

resource "docker_container" "db" {
  name    = "${var.project}-db"
  image   = docker_image.mysql.image_id
  restart = "unless-stopped"

  env = [
    "MYSQL_ROOT_PASSWORD=${var.mysql_root_password}",
    "MYSQL_DATABASE=${var.db_name}",
    "MYSQL_USER=${var.db_user}",
    "MYSQL_PASSWORD=${var.db_password}",
  ]

  volumes {
    volume_name    = docker_volume.db_data.name
    container_path = "/var/lib/mysql"
  }

  networks_advanced {
    name         = docker_network.lb_net.name
    ipv4_address = local.db_ip
  }

  healthcheck {
    test         = ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$MYSQL_ROOT_PASSWORD\" --silent"]
    interval     = "5s"
    timeout      = "5s"
    start_period = "30s"
    retries      = 30
  }

  # Terraform waits until MySQL is healthy before it creates the application servers
  wait         = true
  wait_timeout = 180
}

# ---- Application servers

# app1 starts alone: it creates the tables and, on an empty database, loads the demo data
resource "docker_container" "app_first" {
  name    = "${var.project}-${local.nodes[0].name}"
  image   = data.docker_image.app.id
  restart = "unless-stopped"

  env = concat(local.app_env, [
    "DB_SEED=auto",
    "JAVA_OPTS=${var.java_opts} -DjvmRoute=${local.nodes[0].name}",
  ])

  networks_advanced {
    name         = docker_network.lb_net.name
    ipv4_address = local.nodes[0].ip
  }

  healthcheck {
    test         = local.app_healthcheck.test
    interval     = local.app_healthcheck.interval
    timeout      = local.app_healthcheck.timeout
    start_period = local.app_healthcheck.start_period
    retries      = local.app_healthcheck.retries
  }

  wait         = true
  wait_timeout = 300

  depends_on = [docker_container.db]
}

# The other servers start when app1 is healthy (the tables exist) and never load demo data
resource "docker_container" "app_more" {
  count = var.app_replicas - 1

  name    = "${var.project}-${local.nodes[count.index + 1].name}"
  image   = data.docker_image.app.id
  restart = "unless-stopped"

  env = concat(local.app_env, [
    "DB_SEED=false",
    "JAVA_OPTS=${var.java_opts} -DjvmRoute=${local.nodes[count.index + 1].name}",
  ])

  networks_advanced {
    name         = docker_network.lb_net.name
    ipv4_address = local.nodes[count.index + 1].ip
  }

  healthcheck {
    test         = local.app_healthcheck.test
    interval     = local.app_healthcheck.interval
    timeout      = local.app_healthcheck.timeout
    start_period = local.app_healthcheck.start_period
    retries      = local.app_healthcheck.retries
  }

  wait         = true
  wait_timeout = 300

  depends_on = [docker_container.app_first]
}

# ---- Load balancer

resource "docker_container" "lb" {
  name    = "${var.project}-lb"
  image   = docker_image.nginx.image_id
  restart = "unless-stopped"

  ports {
    internal = 80
    external = var.lb_port
  }

  networks_advanced {
    name         = docker_network.lb_net.name
    ipv4_address = local.lb_ip
  }

  # The config is generated from templates/nginx.conf.tftpl. A change of the
  # algorithm or of the number of servers changes the file and recreates this container.
  upload {
    file    = "/etc/nginx/conf.d/default.conf"
    content = local.nginx_conf
  }

  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/nginx-status"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }

  depends_on = [docker_container.app_first, docker_container.app_more]
}
