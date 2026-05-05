#!/bin/bash

# Azure Healthcare Data Platform Deployment Script
# This script demonstrates Infrastructure as Code and DevOps best practices

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="healthcare-platform"
ENVIRONMENT="dev"
LOCATION="East US"
RESOURCE_GROUP_NAME="${PROJECT_NAME}-${ENVIRONMENT}-rg"

echo -e "${BLUE}🏥 Azure Healthcare Data Platform Deployment${NC}"
echo -e "${BLUE}===============================================${NC}"

# Function to print status
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    print_error "Azure CLI is not installed. Please install it first."
    echo "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

print_status "Azure CLI is installed"

# Check if logged in to Azure
if ! az account show &> /dev/null; then
    print_warning "Not logged into Azure. Please login..."
    az login
fi

print_status "Logged into Azure"

# Get current subscription
SUBSCRIPTION_ID=$(az account show --query id --output tsv)
SUBSCRIPTION_NAME=$(az account show --query name --output tsv)
echo -e "${BLUE}Using subscription:${NC} $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"

# Create resource group
echo -e "\n${BLUE}Creating resource group...${NC}"
az group create \
    --name $RESOURCE_GROUP_NAME \
    --location "$LOCATION" \
    --tags Environment=$ENVIRONMENT Project=$PROJECT_NAME

print_status "Resource group created: $RESOURCE_GROUP_NAME"

# Generate secure password for SQL Server
SQL_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
echo -e "${YELLOW}Generated secure SQL password${NC}"

# Deploy ARM template
echo -e "\n${BLUE}Deploying Azure infrastructure...${NC}"
echo -e "${YELLOW}This may take 10-15 minutes...${NC}"

DEPLOYMENT_NAME="${PROJECT_NAME}-deployment-$(date +%Y%m%d-%H%M%S)"

az deployment group create \
    --resource-group $RESOURCE_GROUP_NAME \
    --template-file ../infrastructure/azure-template.json \
    --parameters \
        projectName=$PROJECT_NAME \
        environment=$ENVIRONMENT \
        sqlAdminPassword=$SQL_PASSWORD \
    --name $DEPLOYMENT_NAME

print_status "Infrastructure deployment completed"

# Get deployment outputs
echo -e "\n${BLUE}Retrieving deployment information...${NC}"

WEB_APP_URL=$(az deployment group show \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $DEPLOYMENT_NAME \
    --query properties.outputs.webAppUrl.value \
    --output tsv)

KEY_VAULT_NAME=$(az deployment group show \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $DEPLOYMENT_NAME \
    --query properties.outputs.keyVaultName.value \
    --output tsv)

STORAGE_ACCOUNT_NAME=$(az deployment group show \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $DEPLOYMENT_NAME \
    --query properties.outputs.storageAccountName.value \
    --output tsv)

SQL_SERVER_NAME=$(az deployment group show \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $DEPLOYMENT_NAME \
    --query properties.outputs.sqlServerName.value \
    --output tsv)

# Configure Key Vault permissions
echo -e "\n${BLUE}Configuring Key Vault access...${NC}"

# Get the web app's managed identity
WEB_APP_PRINCIPAL_ID=$(az webapp identity show \
    --resource-group $RESOURCE_GROUP_NAME \
    --name "${PROJECT_NAME}-${ENVIRONMENT}-webapp" \
    --query principalId \
    --output tsv)

# Grant Key Vault permissions to the web app
az role assignment create \
    --assignee $WEB_APP_PRINCIPAL_ID \
    --role "Key Vault Secrets User" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME"

print_status "Key Vault permissions configured"

# Store database credentials in Key Vault
echo -e "\n${BLUE}Storing secrets in Key Vault...${NC}"

az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name "sql-admin-password" \
    --value $SQL_PASSWORD

az keyvault secret set \
    --vault-name $KEY_VAULT_NAME \
    --name "sql-connection-string" \
    --value "Server=${SQL_SERVER_NAME}.database.windows.net;Database=${PROJECT_NAME}-${ENVIRONMENT}-db;Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;"

print_status "Secrets stored in Key Vault"

# Deploy application code
echo -e "\n${BLUE}Deploying application code...${NC}"

# Create deployment package
cd ../webapp
zip -r ../scripts/app.zip . -x "healthcare-env/*" "__pycache__/*" "*.pyc"

# Deploy to App Service
az webapp deployment source config-zip \
    --resource-group $RESOURCE_GROUP_NAME \
    --name "${PROJECT_NAME}-${ENVIRONMENT}-webapp" \
    --src ../scripts/app.zip

print_status "Application deployed to App Service"

# Cleanup
rm -f ../scripts/app.zip

# Configure App Service settings
echo -e "\n${BLUE}Configuring application settings...${NC}"

az webapp config appsettings set \
    --resource-group $RESOURCE_GROUP_NAME \
    --name "${PROJECT_NAME}-${ENVIRONMENT}-webapp" \
    --settings \
        "FLASK_SECRET_KEY=@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=flask-secret-key)" \
        "SCM_DO_BUILD_DURING_DEPLOYMENT=true" \
        "ENABLE_ORYX_BUILD=true"

print_status "Application settings configured"

# Display deployment summary
echo -e "\n${GREEN}🎉 Deployment completed successfully!${NC}"
echo -e "${GREEN}======================================${NC}"
echo -e "${BLUE}Web Application URL:${NC} $WEB_APP_URL"
echo -e "${BLUE}Resource Group:${NC} $RESOURCE_GROUP_NAME"
echo -e "${BLUE}Key Vault:${NC} $KEY_VAULT_NAME"
echo -e "${BLUE}Storage Account:${NC} $STORAGE_ACCOUNT_NAME"
echo -e "${BLUE}SQL Server:${NC} $SQL_SERVER_NAME"

echo -e "\n${YELLOW}Next Steps:${NC}"
echo -e "1. Visit your application: $WEB_APP_URL"
echo -e "2. Check Application Insights for monitoring"
echo -e "3. Review Key Vault for secure secret management"
echo -e "4. Configure custom domain (optional)"

echo -e "\n${GREEN}Security Features Implemented:${NC}"
echo -e "✓ Managed Identity for secure authentication"
echo -e "✓ Key Vault for secret management"
echo -e "✓ HTTPS enforced on App Service"
echo -e "✓ SQL Database with Azure AD authentication"
echo -e "✓ Blob Storage with private access"
echo -e "✓ Application Insights for monitoring"

echo -e "\n${BLUE}Healthcare Compliance Features:${NC}"
echo -e "✓ Data encryption at rest and in transit"
echo -e "✓ Audit logging enabled"
echo -e "✓ Role-based access control (RBAC)"
echo -e "✓ Secure database connections"
echo -e "✓ Private blob storage for medical documents"