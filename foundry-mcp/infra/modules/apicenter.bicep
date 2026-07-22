// apicenter.bicep — Azure API Center resource (organizational MCP tool catalog)
// The actual MCP server registration is done post-deploy via Register-MCPInApiCenter.ps1

param location string
param apiCenterName string
param tags object

// ── Azure API Center ──────────────────────────────────────────────────────────
resource apiCenter 'Microsoft.ApiCenter/services@2024-03-01' = {
  name:     apiCenterName
  location: location
  tags:     tags
  sku:      { name: 'Free' }   // upgrade to Standard for production governance features
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output apiCenterName       string = apiCenter.name
output apiCenterResourceId string = apiCenter.id
