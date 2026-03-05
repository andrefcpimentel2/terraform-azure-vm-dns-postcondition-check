# ==========================================
# 1. DATA SOURCE: Existing Private DNS Zone
# ==========================================
data "azurerm_private_dns_zone" "existing_zone" {
  name                = var.dns_zone_name   # Replace with your existing Zone Name
  resource_group_name = var.dns_rg_name          # Replace with the RG where the Zone lives
}


# ==========================================
# 2. NEW RESOURCES: VM Infrastructure
# ==========================================
resource "azurerm_resource_group" "vm_rg" {
  name     = var.rg_name
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = "new-vm-vnet"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.vm_rg.location
  resource_group_name = azurerm_resource_group.vm_rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "vm-subnet"
  resource_group_name  = azurerm_resource_group.vm_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.1.1.0/24"]
}

resource "azurerm_network_interface" "nic" {
  name                = "new-vm-nic"
  location            = azurerm_resource_group.vm_rg.location
  resource_group_name = azurerm_resource_group.vm_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "new-vm"
  resource_group_name             = azurerm_resource_group.vm_rg.name
  location                        = azurerm_resource_group.vm_rg.location
  size                            = "DC1ds_v3"
  admin_username                  = "adminuser"
  admin_password                  = var.password # Use SSH keys for production!
  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# ==========================================
# 3. LINK & RECORD: Connect VM to Existing DNS
# ==========================================

# Link the new VNet to the existing Private DNS Zone so the VM can resolve names
resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "link-new-vnet-to-existing-zone"
  
  # Crucially, this resource must be deployed in the Resource Group where the DNS Zone lives
  resource_group_name   = data.azurerm_private_dns_zone.existing_zone.resource_group_name
  private_dns_zone_name = data.azurerm_private_dns_zone.existing_zone.name
  
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# Create the A-Record in the existing DNS Zone using the new VM's NIC IP
resource "azurerm_private_dns_a_record" "vm_record" {
  name                = "newvm" # Will resolve to newvm.internal.mycompany.com
  
  # Target the existing zone details retrieved by the data block
  zone_name           = data.azurerm_private_dns_zone.existing_zone.name
  resource_group_name = data.azurerm_private_dns_zone.existing_zone.resource_group_name
  
  ttl                 = 300
  records             = [azurerm_network_interface.nic.private_ip_address]
}
