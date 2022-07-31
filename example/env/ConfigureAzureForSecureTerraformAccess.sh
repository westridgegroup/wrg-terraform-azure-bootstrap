#!/bin/bash

#############################################################################################################################
#DESCRIPTION
#    Configures Azure for secure Terraform access using Azure Key Vault.
#
#    The following steps are automated:
#    - Creates an Azure Service Principle for Terraform.
#    - Creates a new Resource Group.
#    - Creates a new Storage Account.
#    - Creates a new Storage Container.
#    - Creates a new Key Vault.
#    - Configures Key Vault Access Policies.
#    - Creates Key Vault Secrets for these sensitive Terraform login details:
#        - ARM_SUBSCRIPTION_ID
#        - ARM_CLIENT_ID
#        - ARM_CLIENT_SECRET
#        - ARM_TENANT_ID
#        - ARM_ACCESS_KEY
#	 - If boostrap resources already exist, keys & secrets will be refreshed
#
#VERSION 1.1.0
#
#EXAMPLE
#    az account login
#    ./scripts/ConfigureAzureForSecureTerraformAccess.sh
#
#NOTES
#    Assumptions:
#    - az cli is installed
#    - You are already logged into Azure before running this script (eg.az account login)
#	 - You are in the correct subscription and tenant
#	 - Your account can create app registrations (Everyone[AAD default], Application Administrator, Cloud Application Administrator, or Global Admin)
#	 - Can set permissions on the subscription that you are logged into (User Access Admin, Owner, or Global Admin)
#	 - Can create objects in the subscription that you are logged into (Contributor or Owner)
#
#    Author:  sfibich
#    GitHub:  https://github.com/sfibich
#
#    This script was based on Adam Rush's script ConfigureAzureForSecureTerraformAccess.ps1 https://github.com/adamrushuk.	#
#############################################################################################################################

#Exit on error
set -e

SKIP=FALSE

RESOURCE_GROUP_NAME='terraform-mgmt-rg'
LOCATION='eastus2'
STORAGE_ACCOUNT_SKU='Standard_LRS'
STORAGE_CONTAINER_NAME='terraform-state'

#################################################################################
# Prepend Linux epoch + 4-digit random number with the letter : Assssssssss9999	#
#################################################################################
LETTERS=({a..z})
RANDOM_NUMBER=$(($RANDOM % 10000))
RANDOM_PREFIX=${LETTERS[RANDOM % 26]}$(date +%s | rev | cut -c1-10)$RANDOM_NUMBER
KEY_VAULT_NAME=${LETTERS[RANDOM % 26]}$(date +%s | rev | cut -c1-6)$RANDOM_NUMBER"-terraform-kv"
STORAGE_ACCOUNT_NAME=$RANDOM_PREFIX"terraform"


function check_login() {
#####################
#Check Azure login	#
#####################
echo "Checking for an active Azure login..."

CURRENT_SUBSCRIPTION_ID=$(az account list --query "[?isDefault].id" --output tsv)
TENANT_ID=$(az account list --query "[?isDefault].homeTenantId" --output tsv)

if [ -z "$CURRENT_SUBSCRIPTION_ID" ]
	then 
		printf '%s\n' "ERROR! Not logged in to Azure. Run az account login" >&2
		exit 1
	else
		echo "SUCCESS!"
fi

ADMIN_USER=$(az ad signed-in-user show --query "userPrincipalName" --output tsv)
}


function service_principle() {
#####################
#Service Principle	#
#####################
HASH_CURRENT_SUBSCRIPTION_ID=$(echo -n $CURRENT_SUBSCRIPTION_ID | md5sum | awk '{print $1}' )
echo "HCSID: $HASH_CURRENT_SUBSCRIPTION_ID"

SERVICE_PRINCIPLE_NAME="terraform-$HASH_CURRENT_SUBSCRIPTION_ID"

echo "Checking for an active Service Principle: $SERVICE_PRINCIPLE_NAME..." 

APP_ID=$(az ad app list --query "[?displayName=='$SERVICE_PRINCIPLE_NAME']".appId --output tsv)

if [ -z "$APP_ID" ]
	then 
		echo "Creating a Terraform Service Principle: $SERVICE_PRINCIPLE_NAME ..."
		az ad app create --display-name "$SERVICE_PRINCIPLE_NAME" --output none
		APP_ID=$(az ad app list --query "[?displayName=='$SERVICE_PRINCIPLE_NAME']".appId --output tsv)
		az ad sp create --id $APP_ID --output none
	else
	   	echo "Service Principle exists reseting permissions & password"
		APP_ID=$(az ad app list --query "[?displayName=='$SERVICE_PRINCIPLE_NAME']".appId --output tsv)

fi
az role assignment create --assignee $APP_ID --role Contributor --scope /subscriptions/$CURRENT_SUBSCRIPTION_ID --output none 
az role assignment create --assignee $APP_ID --role "Resource Policy Contributor" --scope /subscriptions/$CURRENT_SUBSCRIPTION_ID --output none 
az role assignment create --assignee $APP_ID --role "User Access Administrator" --scope /subscriptions/$CURRENT_SUBSCRIPTION_ID --output none 

JSON_OUTPUT=$(az ad app credential reset --id $APP_ID)
#echo $JSON_OUTPUT
SEARCH_STRING='\"password\": \"'
FIRST_CUT=${JSON_OUTPUT#*$SEARCH_STRING}; 
#echo $FIRST_CUT
SEARCH_STRING_2='"'
SECOND_CUT=${FIRST_CUT#*$SEARCH_STRING_2}; 
#echo $SECOND_CUT
LENGTH=$(( ${#FIRST_CUT} - ${#SECOND_CUT} - ${#SEARCH_STRING_2} )); 
#echo $LENGTH
PASSWORD=$(echo $FIRST_CUT | cut -c1-$LENGTH)
#echo $PASSWORD
}


function resource_group() {
#####################
#New Resource Group	#
#####################

echo "Creating Terraform Management Resource Group: $RESOURCE_GROUP_NAME"
az group create --name $RESOURCE_GROUP_NAME --location $LOCATION --output none
}

function storage_account() {
#####################
#New Storage Account#
#####################

echo "Creating Terraform backend Storage Account: $STORAGE_ACCOUNT_NAME"
EXISTING_STORAGE_ACCOUNT_NAME=$(az storage account list --query "[?resourceGroup=='$RESOURCE_GROUP_NAME' && contains(@.name, 'terraform')]".name --output tsv)
if [ -z "$EXISTING_STORAGE_ACCOUNT_NAME" ]
	then
		az storage account create --name $STORAGE_ACCOUNT_NAME --resource-group $RESOURCE_GROUP_NAME --sku $STORAGE_ACCOUNT_SKU --output none

		#######################
		#New Storage Container#
		#######################

		AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT_NAME
		echo "Creating Terraform State Storage Container: $STORAGE_CONTAINER_NAME"
		az storage container create --name $STORAGE_CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME --auth-mode login --output none

	else
		echo "Storage Account already exists, using: $EXISTING_STORAGE_ACCOUNT_NAME"
		STORAGE_ACCOUNT_NAME=$(echo $EXISTING_STORAGE_ACCOUNT_NAME)

fi

#######################
#Reset Secondary Key  #
#######################
JSON_OUTPUT=$(az storage account keys renew --account-name $STORAGE_ACCOUNT_NAME --resource-group $RESOURCE_GROUP_NAME --key secondary)
#echo $JSON_OUTPUT
SEARCH_STRING='"keyName": "key2",'
FIRST_CUT=${JSON_OUTPUT#*$SEARCH_STRING}
#echo $FIRST_CUT
#ASSUMES KEY comes before VALUE...bad assumption but works
SEARCH_STRING_2='"value": "'
SECOND_CUT=${FIRST_CUT#*$SEARCH_STRING_2}
#echo $SECOND_CUT
SEARCH_STRING_3='"'
THIRD_CUT=${SECOND_CUT#*$SEARCH_STRING_3}
#echo $THIRD_CUT
LENGTH=$(( ${#SECOND_CUT} - ${#THIRD_CUT} - ${#SEARCH_STRING_3} ))
#echo $LENGTH
ARM_ACCESS_KEY=$(echo $SECOND_CUT | cut -c1-$LENGTH)
#echo $PASSWORD
}


function key_vault() {
#####################
#New KeyVault		#
#####################
echo "Creating Terraform KeyVault: $KEY_VAULT_NAME"
EXISTING_KEY_VAULT_NAME=$(az keyvault list --query "[?resourceGroup=='$RESOURCE_GROUP_NAME' && contains(@.name, 'terraform-kv')]".name --output tsv)
if [ -z "$EXISTING_KEY_VAULT_NAME" ]
	then
		az keyvault create --location $LOCATION --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP_NAME --output none
	else
		echo "Key Vault already exists, using: $EXISTING_KEY_VAULT_NAME"
		KEY_VAULT_NAME=$(echo $EXISTING_KEY_VAULT_NAME)
fi

#############################	
#Set KeyVault Access Policy	#
#############################
echo "Setting KeyVault Access Policy for Owner: $ADMIN_USER"
KEY_VAULT_ID=$(az keyvault list --query "[?name=='$KEY_VAULT_NAME'].id" --output tsv)
az role assignment create --assignee $ADMIN_USER --role Owner --scope $KEY_VAULT_ID --output none 

}

function set_secrets() {
#############################
#Create KeyVault Secrets	#
#############################
echo "Creating KeyVault Secrets for Terraform"
az keyvault secret set --name ARM-SUBSCRIPTION-ID --value $CURRENT_SUBSCRIPTION_ID --vault-name $KEY_VAULT_NAME --output none
az keyvault secret set --name ARM-CLIENT-ID --value $APP_ID --vault-name $KEY_VAULT_NAME --output none
az keyvault secret set --name ARM-CLIENT-SECRET --value $PASSWORD --vault-name $KEY_VAULT_NAME --output none
az keyvault secret set --name ARM-TENANT-ID --value $TENANT_ID --vault-name $KEY_VAULT_NAME --output none
az keyvault secret set --name ARM-ACCESS-KEY --value $ARM_ACCESS_KEY --vault-name $KEY_VAULT_NAME --output none

#################
# Ending Output	#
#################
echo "Terraform resources provisioned:"
echo "SERVICE_PRINCIPLE_NAME:$SERVICE_PRINCIPLE_NAME"
echo "RESOURCE_GROUP_NAME:$RESOURCE_GROUP_NAME"
echo "LOCATION:$LOCATION"
echo "CONTAINER_NAME:$STORAGE_CONTAINER_NAME"
echo "STORAGE_ACCOUNT_NAME:$STORAGE_ACCOUNT_NAME"
echo "KEY_VAULT_NAME:$KEY_VAULT_NAME"

}
#####################
#		MAIN		#
#####################

if [[ $SKIP == "FALSE" ]]
	then
		check_login
		service_principle
		resource_group
		storage_account
		key_vault
		set_secrets
		echo "FINISHED!"

	else
		check_login
		service_principle
		resource_group
		storage_account
		key_vault
		set_secrets
		echo "FINISHED SKIPPED!"
fi
