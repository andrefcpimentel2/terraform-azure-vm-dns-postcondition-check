variable "rg_name" {
  description = "Name of the Resource Group where the Private DNS Zone will be created"
  type        = string
  default     = "new-dns-rg"
}

variable "location" {
  description = "Location of the Resource Group and Private DNS Zone"
  type        = string
  default     = "uksouth"
}

variable "dns_zone_name" {
  description = "Name of the Private DNS Zone to create"
  type        = string
  default     = "internal.mycompany.com"
  
}