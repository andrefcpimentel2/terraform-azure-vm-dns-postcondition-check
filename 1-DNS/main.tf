# 1. RG
resource "azurerm_resource_group" "vm_rg" {
  name     = var.rg_name
  location = var.location
}

# 2. Azure Private DNS Zone
resource "azurerm_private_dns_zone" "dns_zone" {
  name                = var.dns_zone_name
  resource_group_name = azurerm_resource_group.vm_rg.name
}
