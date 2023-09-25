terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.71.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  resource_group = "app_rgdeep"
  location       = "West Europe"
}

resource "azurerm_resource_group" "app_rgdeep" {
  name     = local.resource_group
  location = local.location
}


data "azurerm_client_config" "current" {}

data "template_cloudinit_config" "linuxconfig" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content      = "packages: ['nginx']"
  }
}

resource "tls_private_key" "linux_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# We want to save the private key to our machine
# We can then use this key to connect to our Linux VM

resource "local_file" "linuxkey" {
  filename = "linuxkey.pem"
  content  = tls_private_key.linux_key.private_key_pem
}

resource "azurerm_virtual_network" "app_network" {
  name                = "app-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.app_rgdeep.location
  resource_group_name = azurerm_resource_group.app_rgdeep.name
}

resource "azurerm_subnet" "subnet1" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.app_rgdeep.name
  virtual_network_name = azurerm_virtual_network.app_network.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_network_interface" "app_interface" {
  name                = "app-interface"
  location            = azurerm_resource_group.app_rgdeep.location
  resource_group_name = azurerm_resource_group.app_rgdeep.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet1.id
    private_ip_address_allocation = "Dynamic"
  }
  depends_on = [
    azurerm_virtual_network.app_network,
    azurerm_subnet.subnet1
  ]
}

resource "azurerm_network_interface" "app_interface1" {
  name                = "app-interface1"
  location            = azurerm_resource_group.app_rgdeep.location
  resource_group_name = azurerm_resource_group.app_rgdeep.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet1.id
    private_ip_address_allocation = "Dynamic"
  }
  depends_on = [
    azurerm_virtual_network.app_network,
    azurerm_subnet.subnet1
  ]
}

resource "azurerm_windows_virtual_machine" "app_vm" {
  name                = "deep-machine"
  resource_group_name = azurerm_resource_group.app_rgdeep.name
  location            = azurerm_resource_group.app_rgdeep.location
  size                = "standard_ds1_v2"
  admin_username      = "adminuser"
  admin_password      = azurerm_key_vault_secret.vmpassword.value
  availability_set_id = azurerm_availability_set.app_set.id
  network_interface_ids = [
    azurerm_network_interface.app_interface.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }
}

resource "azurerm_linux_virtual_machine" "linux_vm" {
  name                = "linuxvm"
  resource_group_name = azurerm_resource_group.app_rgdeep.name
  location            = azurerm_resource_group.app_rgdeep.location
  size                = "standard_ds1_v2"
  admin_username      = "adminuser"
  admin_password      = azurerm_key_vault_secret.vmpassword.value
  availability_set_id = azurerm_availability_set.app_set.id
  custom_data         = data.template_cloudinit_config.linuxconfig.rendered
  network_interface_ids = [
    azurerm_network_interface.app_interface1.id,
  ]

  admin_ssh_key {
    username   = "adminuser"
    public_key = tls_private_key.linux_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }

  depends_on = [
    azurerm_network_interface.app_interface1,
    azurerm_availability_set.app_set
  ]
}

resource "azurerm_availability_set" "app_set" {
  name                         = "app-set"
  location                     = azurerm_resource_group.app_rgdeep.location
  resource_group_name          = azurerm_resource_group.app_rgdeep.name
  platform_fault_domain_count  = 3
  platform_update_domain_count = 3
  depends_on = [
    azurerm_resource_group.app_rgdeep
  ]
}

resource "azurerm_storage_account" "appstore" {
  name                     = "appstore15081978"
  resource_group_name      = azurerm_resource_group.app_rgdeep.name
  location                 = azurerm_resource_group.app_rgdeep.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "data" {
  name                  = "data"
  storage_account_name  = "appstore15081978"
  container_access_type = "blob"
  depends_on = [
    azurerm_storage_account.appstore
  ]
}

# Here we are uploading our IIS Configuration script as a blob
#to the Azure storage account
resource "azurerm_storage_blob" "IIS_Config" {
  name                   = "IIS_Config.ps1"
  storage_account_name   = "appstore15081978"
  storage_container_name = "data"
  type                   = "Block"
  source                 = "${path.module}/IIS_Config.ps1"
  depends_on             = [azurerm_storage_container.data]
}

resource "azurerm_virtual_machine_extension" "vm_extension" {
  name                 = "appvm_extension"
  virtual_machine_id   = azurerm_windows_virtual_machine.app_vm.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"
  depends_on = [
    azurerm_storage_blob.IIS_Config
  ]

  settings = <<SETTINGS
 {
  "fileUris": ["https://${azurerm_storage_account.appstore.name}.blob.core.windows.net/data/IIS_Config.ps1"],
    "commandToExecute": "powershell -ExecutionPolicy Unrestricted -file IIS_Config.ps1"
 }
SETTINGS
}


resource "azurerm_network_security_group" "app_nsg" {
  name                = "app-nsg"
  location            = azurerm_resource_group.app_rgdeep.location
  resource_group_name = azurerm_resource_group.app_rgdeep.name


  # We are creating a rule to allow traffic on port 80
  security_rule {
    name                       = "Allow_HTTP"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg_association" {
  subnet_id                 = azurerm_subnet.subnet1.id
  network_security_group_id = azurerm_network_security_group.app_nsg.id
  depends_on = [
    azurerm_network_security_group.app_nsg
  ]
}


resource "azurerm_key_vault" "app_vault" {
  name                       = "appvault19012010"
  location                   = azurerm_resource_group.app_rgdeep.location
  resource_group_name        = azurerm_resource_group.app_rgdeep.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  sku_name = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = [
      "Get",
    ]
    secret_permissions = [
      "Get", "Backup", "Delete", "List", "Purge", "Recover", "Restore", "Set",
    ]

    storage_permissions = [
      "Get",
    ]
  }
  depends_on = [
    azurerm_resource_group.app_rgdeep
  ]
}


# We are creating a secret in the key vault
resource "azurerm_key_vault_secret" "vmpassword" {
  name         = "vmpassword"
  value        = "Welcome@12345"
  key_vault_id = azurerm_key_vault.app_vault.id
  depends_on   = [azurerm_key_vault.app_vault]
}

resource "azurerm_public_ip" "load_ip" {
  name                = "load-ip"
  location            = azurerm_resource_group.app_rgdeep.location
  resource_group_name = azurerm_resource_group.app_rgdeep.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "app_balancer" {
  name                = "app-balancer"
  location            = azurerm_resource_group.app_rgdeep.location
  resource_group_name = azurerm_resource_group.app_rgdeep.name

  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.load_ip.id
  }
  sku = "Standard"
  depends_on = [
    azurerm_public_ip.load_ip
  ]
}

resource "azurerm_lb_backend_address_pool" "PoolA" {
  loadbalancer_id = azurerm_lb.app_balancer.id
  name            = "PoolA"

  depends_on = [
    azurerm_lb.app_balancer
  ]
}

resource "azurerm_lb_backend_address_pool_address" "deep-machine_address" {
  name                    = "deep-machine"
  backend_address_pool_id = azurerm_lb_backend_address_pool.PoolA.id
  virtual_network_id      = azurerm_virtual_network.app_network.id
  ip_address              = azurerm_network_interface.app_interface.private_ip_address
  depends_on = [
    azurerm_lb_backend_address_pool.PoolA
  ]
}

resource "azurerm_lb_backend_address_pool_address" "linuxvm_address" {
  name                    = "linuxvm"
  backend_address_pool_id = azurerm_lb_backend_address_pool.PoolA.id
  virtual_network_id      = azurerm_virtual_network.app_network.id
  ip_address              = azurerm_network_interface.app_interface1.private_ip_address
  depends_on = [
    azurerm_lb_backend_address_pool.PoolA
  ]
}

resource "azurerm_lb_probe" "ProbeA" {
  loadbalancer_id = azurerm_lb.app_balancer.id
  name            = "ProbeA"
  port            = 80
  depends_on = [
    azurerm_lb.app_balancer
  ]
}

resource "azurerm_lb_rule" "RuleA" {
  loadbalancer_id                = azurerm_lb.app_balancer.id
  name                           = "LBRule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "frontend-ip"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.PoolA.id]
  probe_id                       = azurerm_lb_probe.ProbeA.id
  depends_on = [
    azurerm_lb.app_balancer,
    azurerm_lb_probe.ProbeA
  ]
}
