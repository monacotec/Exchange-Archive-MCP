using '../main.bicep'

param environment         = 'dev'
param location            = 'eastus2'
param baseName            = 'gipartners'
param enableManagedVnet   = false   // managed VNet off for dev — avoids irreversible commitment
param itAdminGroupObjectId = '<FILL: Entra ID IT Admin security group object ID>'
param gpt4oTpmK           = 30     // minimal quota for dev testing
