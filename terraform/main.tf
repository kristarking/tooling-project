terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.57.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# ---------------- RESOURCE GROUP ----------------
resource "azurerm_resource_group" "rg" {
  name     = "tooling-rg"
  location = "West Europe"
}

# ---------------- LOG ANALYTICS ----------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "tooling-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
}

# ---------------- ACR ----------------
resource "azurerm_container_registry" "acr" {
  name                = "toolingacr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

# ---------------- AKS ----------------
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "tooling-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "tooling"

  default_node_pool {
    name                = "system"
    vm_size             = "Standard_DS2_v2"
    auto_scaling_enabled = true
    min_count           = 2
    max_count           = 5
    node_count          = 2 
  }

  identity {
    type = "SystemAssigned"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
    load_balancer_sku = "standard"
  }
}

# ---------------- AKS → ACR PERMISSION ----------------
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}
