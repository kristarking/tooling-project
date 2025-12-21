# ---------------- AZURE STORAGE ACCOUNT FOR TERRAFORM STATE ----------------
terraform {
  backend "azurerm" {
    resource_group_name  = "tooling-tfstate-rg"
    storage_account_name = "toolingtfstateprod"
    container_name       = "tfstate"
    key                  = "tooling.tfstate"
  }
}
