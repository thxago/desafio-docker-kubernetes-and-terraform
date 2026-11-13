variable "cluster_name" {
  description = "Unique name for this Terraform-owned kind cluster."
  type        = string
  default     = "mural-terraform"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,29}[a-z0-9]$", var.cluster_name))
    error_message = "Use 2-31 lowercase letters, digits or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "node_image" {
  type    = string
  default = "kindest/node:v1.34.0"
}

variable "platform" {
  type    = string
  default = "linux/amd64"
  validation {
    condition     = contains(["linux/amd64", "linux/arm64"], var.platform)
    error_message = "Use linux/amd64 or linux/arm64, matching the kind node architecture."
  }
}

variable "http_port" {
  type    = number
  default = 80
}

variable "https_port" {
  type    = number
  default = 443
  validation {
    condition     = alltrue([for port in [var.http_port, var.https_port] : port >= 1 && port <= 65535 && floor(port) == port]) && var.http_port != var.https_port
    error_message = "HTTP and HTTPS ports must be distinct integers between 1 and 65535."
  }
}

variable "host" {
  type    = string
  default = "mural.localtest.me"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.host))
    error_message = "Provide a hostname without scheme, path or port."
  }
}

variable "postgres_username" {
  type    = string
  default = "mural"
}

variable "postgres_database" {
  type    = string
  default = "mural"
}

variable "postgres_password" {
  description = "Supply through TF_VAR_postgres_password or an ignored private tfvars file."
  type        = string
  sensitive   = true
  nullable    = false
  validation {
    condition     = length(var.postgres_password) >= 16
    error_message = "Provide a password of at least 16 characters."
  }
}

variable "postgres_image" {
  type = object({
    repository = string
    tag        = string
  })
  default = {
    repository = "postgres"
    tag        = "16-alpine"
  }
}

variable "traefik_chart_version" {
  type    = string
  default = "37.4.0"
}

variable "traefik_image_tag" {
  description = "Must match a version supported by the selected Traefik chart."
  type        = string
  default     = "v3.6.2"
}

variable "mural_values" {
  description = "Additional chart values (replicas, resource requests/limits, persistence, API ports). Terraform owns image tags, ingress routing and credentials."
  type        = any
  default     = {}
}

variable "enable_autoscaling" {
  description = "Install metrics-server and enable the API HPA in this local kind cluster."
  type        = bool
  default     = false
}

variable "metrics_server_chart_version" {
  type    = string
  default = "3.13.0"
}

variable "metrics_server_image_tag" {
  type    = string
  default = "v0.8.0"
}