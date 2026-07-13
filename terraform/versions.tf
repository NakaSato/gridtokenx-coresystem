terraform {
  required_version = ">= 1.6"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
  }
}

variable "docker_host" {
  description = "Docker daemon socket. OrbStack/Docker Desktop both expose the default unix socket."
  type        = string
  default     = "unix:///var/run/docker.sock"
}

provider "docker" {
  host = var.docker_host
}
