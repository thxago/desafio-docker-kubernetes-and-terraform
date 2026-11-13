terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "= 0.13.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.5.0"
    }
  }
}

provider "kind" {}

provider "kubernetes" {
  host                   = kind_cluster.mural.endpoint
  client_certificate     = kind_cluster.mural.client_certificate
  client_key             = kind_cluster.mural.client_key
  cluster_ca_certificate = kind_cluster.mural.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = kind_cluster.mural.endpoint
    client_certificate     = kind_cluster.mural.client_certificate
    client_key             = kind_cluster.mural.client_key
    cluster_ca_certificate = kind_cluster.mural.cluster_ca_certificate
  }
}