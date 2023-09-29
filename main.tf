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
