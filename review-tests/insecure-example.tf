# Example resources used only to test the pull request review workflow.
# This file is never applied.

resource "azurerm_network_security_rule" "admin_access" {
  name                        = "allow-admin"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = "tooling-rg"
  network_security_group_name = "tooling-nsg"
}

resource "azurerm_role_assignment" "pipeline_access" {
  principal_id         = "00000000-0000-0000-0000-000000000000"
  role_definition_name = "Owner"
  scope                = "/subscriptions/00000000-0000-0000-0000-000000000000"
}

resource "azurerm_mysql_flexible_server" "db" {
  name                   = "tooling-mysql"
  resource_group_name    = "tooling-rg"
  location               = "westeurope"
  administrator_login    = "admin"
  administrator_password = "Password123!"
  sku_name               = "B_Standard_B1ms"
}
