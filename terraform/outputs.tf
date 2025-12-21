# ---------------- RESOURCE GROUP ----------------
output "resource_group_name" {
  description = "Resource group where all resources are deployed"
  value       = azurerm_resource_group.rg.name
}

output "resource_group_location" {
  description = "Azure region"
  value       = azurerm_resource_group.rg.location
}

# ---------------- ACR OUTPUTS ----------------
output "acr_name" {
  description = "Azure Container Registry name"
  value       = azurerm_container_registry.acr.name
}

output "acr_login_server" {
  description = "ACR login server URL"
  value       = azurerm_container_registry.acr.login_server
}

# ---------------- AKS OUTPUTS ----------------
output "aks_cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.aks.name
}

output "aks_resource_group" {
  description = "Resource group containing AKS"
  value       = azurerm_resource_group.rg.name
}

output "aks_node_resource_group" {
  description = "AKS node resource group"
  value       = azurerm_kubernetes_cluster.aks.node_resource_group
}

# ---------------- AKS IDENTITY ----------------
output "aks_kubelet_identity_object_id" {
  description = "AKS kubelet managed identity object ID"
  value       = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

# ---------------- LOG ANALYTICS ----------------
output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID"
  value       = azurerm_log_analytics_workspace.law.id
}
