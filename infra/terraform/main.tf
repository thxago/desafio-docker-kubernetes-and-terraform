locals {
  root       = abspath("${path.module}/../..")
  chart      = abspath("${path.module}/../helm/mural")
  script     = abspath("${path.module}/scripts/images.ps1")
  kubeconfig = abspath("${path.module}/.runtime/${var.cluster_name}.kubeconfig")
  api_files  = setunion(fileset(local.root, "app/api/**"), fileset(local.root, "app/docker/api.Dockerfile*"))
  web_files  = setunion(fileset(local.root, "app/web/**"), fileset(local.root, "app/docker/web.Dockerfile*"))
  api_hash   = sha256(join("", [for file in sort(tolist(local.api_files)) : "${file}:${filesha256("${local.root}/${file}")}"]))
  web_hash   = sha256(join("", [for file in sort(tolist(local.web_files)) : "${file}:${filesha256("${local.root}/${file}")}"]))
  chart_hash = sha256(join("", [for file in sort(tolist(fileset(local.chart, "**"))) : "${file}:${filesha256("${local.chart}/${file}")}"]))
  api_image  = "${var.cluster_name}-api:tf-${substr(local.api_hash, 0, 12)}"
  web_image  = "${var.cluster_name}-web:tf-${substr(local.web_hash, 0, 12)}"
  postgres   = "${var.postgres_image.repository}:${var.postgres_image.tag}"
  traefik    = "traefik:${var.traefik_image_tag}"
  url        = "http://${var.host}${var.http_port == 80 ? "" : ":${var.http_port}"}"
  image_config = {
    root       = local.root
    cluster    = var.cluster_name
    platform   = var.platform
    api        = local.api_image
    web        = local.web_image
    postgres   = local.postgres
    traefik    = local.traefik
    node       = var.node_image
    kubeconfig = local.kubeconfig
  }
}

resource "terraform_data" "images" {
  input = local.image_config
  triggers_replace = [
    local.api_hash, local.web_hash, var.platform, var.node_image,
    local.postgres, local.traefik, var.cluster_name, filesha256(local.script)
  ]

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
    command     = "& '${replace(local.script, "'", "''")}' -Action Build"
    environment = {
      MURAL_CONFIG = jsonencode(self.input)
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
    command     = "& '${replace(path.module, "'", "''")}/scripts/images.ps1' -Action Remove"
    environment = {
      MURAL_CONFIG = jsonencode(self.input)
    }
  }
}

resource "kind_cluster" "mural" {
  name            = var.cluster_name
  node_image      = var.node_image
  wait_for_ready  = true
  kubeconfig_path = local.kubeconfig

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    node {
      role = "control-plane"
      labels = {
        ingress-ready = "true"
      }
      extra_port_mappings {
        container_port = 30080
        host_port      = var.http_port
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 30443
        host_port      = var.https_port
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
    }
  }

  depends_on = [terraform_data.images]
}

resource "terraform_data" "loaded_images" {
  input = local.image_config
  triggers_replace = [
    terraform_data.images.id, kind_cluster.mural.id,
    kind_cluster.mural.endpoint, kind_cluster.mural.client_certificate
  ]
  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
    command     = "& '${replace(local.script, "'", "''")}' -Action Load"
    environment = {
      MURAL_CONFIG = jsonencode(self.input)
    }
  }
}

resource "kubernetes_namespace_v1" "mural" {
  metadata {
    name = "mural"
  }
}

resource "kubernetes_secret_v1" "database" {
  metadata {
    name      = "mural-database"
    namespace = kubernetes_namespace_v1.mural.metadata[0].name
  }
  data = {
    password = var.postgres_password
    database-url = format(
      "postgres://%s:%s@mural-postgres:5432/%s?sslmode=disable",
      replace(urlencode(var.postgres_username), "+", "%20"),
      replace(urlencode(var.postgres_password), "+", "%20"),
      replace(urlencode(var.postgres_database), "+", "%20")
    )
  }
  type = "Opaque"
}

resource "helm_release" "traefik" {
  name             = "traefik"
  namespace        = "traefik"
  create_namespace = true
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  wait             = true
  timeout          = 600
  values = [
    file("${path.module}/../traefik-values.yaml"),
    yamlencode({ image = { tag = var.traefik_image_tag } })
  ]
  depends_on = [terraform_data.loaded_images]
}

resource "helm_release" "mural" {
  name          = "mural"
  namespace     = kubernetes_namespace_v1.mural.metadata[0].name
  chart         = local.chart
  wait          = true
  wait_for_jobs = true
  timeout       = 600
  values = [
    yamlencode(var.mural_values),
    yamlencode({
      fullnameOverride = "mural"
      api = {
        image = { repository = "${var.cluster_name}-api", tag = "tf-${substr(local.api_hash, 0, 12)}", pullPolicy = "IfNotPresent" }
      }
      web = {
        image = { repository = "${var.cluster_name}-web", tag = "tf-${substr(local.web_hash, 0, 12)}", pullPolicy = "IfNotPresent" }
      }
      postgres = {
        image          = var.postgres_image
        username       = var.postgres_username
        database       = var.postgres_database
        existingSecret = kubernetes_secret_v1.database.metadata[0].name
        password       = ""
      }
      ingress = {
        enabled   = true
        className = "traefik"
        host      = var.host
      }
      terraform = { chartDigest = local.chart_hash }
    })
  ]
  depends_on = [helm_release.traefik, terraform_data.loaded_images]
}

resource "terraform_data" "ready" {
  input = {
    cluster = var.cluster_name
    host    = var.host
    port    = var.http_port
  }
  triggers_replace = [
    helm_release.mural.id, local.chart_hash, sha256(jsonencode(var.mural_values)),
    terraform_data.loaded_images.id, var.host, var.http_port
  ]
  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
    command     = "& '${replace(local.script, "'", "''")}' -Action Wait"
    environment = {
      MURAL_CONFIG = jsonencode(self.input)
    }
  }
  depends_on = [helm_release.mural]
}