// =============================================================================
// managed-cleanroom.bicepparam
// =============================================================================
// Example parameter file for managed-cleanroom.bicep.
// Copy and edit the placeholder values, then deploy:
//
//   az deployment group create \
//     --resource-group <collab-rg> \
//     --template-file  ./managed-cleanroom.bicep \
//     --parameters     ./managed-cleanroom.bicepparam
// =============================================================================
using './managed-cleanroom.bicep'

param collaborationName = '<collaboration-name>'

// ARM RP location (control plane). Keep aligned with $rpLocation in README-API.md.
param rpLocation = 'westus'

// Where the clean-room infra (AKS, CCF, confidential ACI) is provisioned.
param resourceLocation = 'westus'

// Owner is added at creation time. userIdentifier = email (user) or appId (SPN).
param collaborators = [
  {
    userIdentifier: '<woodgrove-email>'
  }
]
