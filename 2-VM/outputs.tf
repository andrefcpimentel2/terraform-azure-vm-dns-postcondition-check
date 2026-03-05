# ==========================================
# 4. OUTPUTS
# ==========================================
output "vm_private_ip" {
  value       = azurerm_network_interface.nic.private_ip_address
  description = "The private IP address of the newly created VM."
}

output "vm_fqdn" {
  value       = "${azurerm_private_dns_a_record.vm_record.name}.${data.azurerm_private_dns_zone.existing_zone.name}"
  description = "The fully qualified domain name registered in the existing DNS zone."
}