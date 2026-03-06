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

resource "azurerm_network_security_group" "nsg" {
  name                = "vm-nsg"
  location            = azurerm_resource_group.vm_rg.location
  resource_group_name = azurerm_resource_group.vm_rg.name

  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
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

resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# ==========================================
# AZURE KEY VAULT & CERTIFICATE
# ==========================================

#Random pet name for unique AZKV
resource "random_pet" "kv_name" {
  length  = 3
}

# Fetch current Azure context (Tenant ID, Object ID) for Key Vault Access Policy
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                        = "${random_pet.kv_name.id}-kv" # Must be globally unique
  location                    = azurerm_resource_group.vm_rg.location
  resource_group_name         = azurerm_resource_group.vm_rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  purge_protection_enabled    = false

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    certificate_permissions = [
      "Create", "Delete", "Get", "List", "Update", "Purge"
    ]
    secret_permissions = [
      "Get", "Set", "List", "Delete", "Purge"
    ]
  }
}

resource "azurerm_key_vault_certificate" "cert" {
  name         = "example-vm-cert"
  key_vault_id = azurerm_key_vault.kv.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }
    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }
    lifetime_action {
      action {
        action_type = "AutoRenew"
      }
      trigger {
        days_before_expiry = 30
      }
    }
    secret_properties {
      content_type = "application/x-pkcs12"
    }
    x509_certificate_properties {
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"] # Server Authentication
      key_usage          = ["cRLSign", "dataEncipherment", "digitalSignature", "keyAgreement", "keyCertSign", "keyEncipherment"]
      subject            = "CN=example-vm.local"
      validity_in_months = 12
    }
  }

  # --- POSTCONDITION ---
  # Checks validity at the exact moment the resource is created/updated
  lifecycle {
    postcondition {
      condition     = self.certificate_attribute[0].enabled == true
      error_message = "Postcondition failed: The provisioned Key Vault Certificate is disabled."
    }
  }
}


resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "new-vm"
  resource_group_name             = azurerm_resource_group.vm_rg.name
  location                        = azurerm_resource_group.vm_rg.location
  size                            = "Standard_D2s_v3"
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

   # Installs Nginx so the HTTP checks have an endpoint to hit
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx
    mkdir -p /etc/nginx/ssl
    echo "some file content" | tee /etc/nginx/ssl/nginx.crt
    systemctl start nginx
    systemctl enable nginx
  EOF
  )
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


# ===========================================================================
# 5. TERRAFORM CHECK BLOCKS (Continuous Validation)
# ===========================================================================

# CHECK 1: Ensure DNS is valid
check "dns_is_valid" {
  assert {
    # Validates that Azure successfully assigned Azure Nameservers to the Zone
    # confirming it is a healthy, active DNS Zone deployment.
    condition     = data.azurerm_private_dns_zone.existing_zone.number_of_record_sets > 0
    error_message = "The DNS Zone is invalid or did not successfully receive name servers from Azure."
  }
}

# CHECK 2: Ensure the machine address is reachable
check "machine_is_reachable" {
  # We use a scoped data source that attempts an actual HTTP connection to the VM's public IP
  data "http" "vm_reachability" {
    url = "http://${azurerm_linux_virtual_machine.vm.public_ip_address}"

    # Retries give the VM and Nginx cloud-init script time to boot and start serving HTTP
    retry {
      attempts     = 10
      min_delay_ms = 5000
      max_delay_ms = 10000
    }
  }

  assert {
    # If the VM isn't responding, this assertion fails and triggers a warning
    condition     = data.http.vm_reachability.status_code == 200
    error_message = "The Virtual Machine public IP is not reachable over HTTP (Port 80)."
  }
}

# CHECK 3: Ensure the DNS A record maps precisely to the VM's public IP
check "dns_record_mapping_is_correct" {
  assert {
    # Validates the Terraform state mapping strictly matches
    condition     = contains(azurerm_private_dns_a_record.vm_record.records, azurerm_linux_virtual_machine.vm.public_ip_address)
    error_message = "The DNS A Record does not map to the current VM's Public IP address."
  }
}

# CHECK 4: Ensure the machine is reachable by its domain name (Active Resolution Test)
check "fqdn_is_reachable" {
  data "http" "vm_reachability_fqdn" {
    # Constructs the full URL (e.g., http://app.mycustomdomain.com)
    url = "http://${azurerm_private_dns_a_record.vm_record.fqdn}"

    retry {
      attempts     = 10
      min_delay_ms = 5000
      max_delay_ms = 15000
    }
  }

  assert {
    condition     = data.http.vm_reachability_fqdn.status_code == 200
    error_message = "The VM is not reachable via its Fully Qualified Domain Name (${azurerm_private_dns_a_record.vm_record.fqdn}). Ensure DNS has propagated and your nameservers are delegated at your domain registrar."
  }
}

# CHECK 5: Check Certificate Validity 
check "verify_certificate_validity" {
    #Using a data source as attributes here have more insights than the actual resource
    data "azurerm_key_vault_certificate" "validation_cert" {
    name         = azurerm_key_vault_certificate.cert.name
    key_vault_id = azurerm_key_vault.kv.id
  }

  # Assertion 1: Check if the certificate is enabled
  assert {
    condition     = azurerm_key_vault_certificate.cert.certificate_attribute[0].enabled == true
    error_message = "Check failed: The Key Vault certificate is currently disabled."
  }

  # Assertion 2: Check if the certificate is expired by comparing 'expires' date with the current time
  assert {
    condition     = timecmp(data.azurerm_key_vault_certificate.validation_cert.expires, plantimestamp()) == 1
    error_message = "Check failed: The Key Vault certificate has expired."
  }

  # Assertion 3: Check if the certificate is expiring within the next month (30 days)
  assert {
    condition     = data.azurerm_key_vault_certificate.validation_cert.certificate_policy[0].x509_certificate_properties[0].validity_in_months <= 1
    error_message = "Check failed: The Key Vault certificate is expiring in less than 1 month."
  }
}