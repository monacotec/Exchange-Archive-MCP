using '../main.bicep'

param environment         = 'prod'
param location            = 'eastus2'
param baseName            = 'gipartners'
param enableManagedVnet   = true
param itAdminGroupObjectId = '<FILL: Entra ID IT Admin security group object ID>'
param gpt4oTpmK           = 150
