terraform {
  backend "azurerm" {
    resource_group_name = "rgdeep3"
    storage_account_name = "deep3"
    container_name = "tfstate"
    key = "terraform.tfstate"
  }
}
