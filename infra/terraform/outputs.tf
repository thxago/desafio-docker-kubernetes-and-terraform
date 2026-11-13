output "url" {
  description = "Mural URL, returned only after Ingress answers for frontend and API."
  value       = local.url
  depends_on  = [terraform_data.ready]
}

output "cluster_name" {
  value = kind_cluster.mural.name
}

output "context" {
  value = kind_cluster.mural.context_name
}

output "kubeconfig_path" {
  description = "Private kubeconfig dedicated to this cluster; never commit it."
  value       = local.kubeconfig
}

output "images" {
  value = {
    api = local.api_image
    web = local.web_image
  }
}