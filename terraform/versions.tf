terraform {
  required_version = ">= 1.6.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.0"
    }
  }

  # State in a local file. Jenkins points it to its own file:
  #   terraform init -backend-config="path=/var/jenkins_home/tfstate/travelagency.tfstate"
  backend "local" {}
}

provider "docker" {
  host = var.docker_host
}
