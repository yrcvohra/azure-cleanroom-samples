<#
.SYNOPSIS
    Deploys the managed clean-room collaboration via Bicep, then performs the
    ARM *action* steps that Bicep cannot express (enableWorkload, addCollaborator).

.DESCRIPTION
    Run by: Collaboration owner (Woodgrove).

    Bicep is declarative and can only create the collaboration *resource*
    (control-plane PUT). The managed clean-room flow also requires imperative
    ARM *action* POSTs which have no declarative Bicep equivalent:

        1. Deploy Bicep            -> creates Microsoft.CleanRoom/collaborations
        2. enableWorkload (POST)   -> enables the Analytics workload
        3. addCollaborator (POST)  -> (optional) invite additional collaborators

    Everything after this (accept invitation, OIDC, publish datasets/queries,
    vote, run) is dataplane/frontend REST -- follow README-API.md Steps 03-12.

    This mirrors README-API.md Steps 02.2 - 02.4 and Appendix F (ARM API).

.PARAMETER resourceGroup
    Resource group for the collaboration control-plane resource ($collabRg).

.PARAMETER collaborationName
    Name of the collaboration ($collabName).

.PARAMETER rpLocation
    ARM RP location for the collaboration resource (default: westus).

.PARAMETER resourceLocation
    Region where clean-room infra (AKS/CCF/CACI) is provisioned (default: westus).

.PARAMETER ownerIdentifier
    Owner email (user) or appId (SPN) added as a collaborator at creation time.

.PARAMETER additionalCollaborators
    Optional list of extra collaborator identifiers to invite via addCollaborator.

.PARAMETER workloadType
    Workload to enable (default: Analytics).

.PARAMETER apiVersion
    Microsoft.CleanRoom ARM API version (default: 2026-04-30-preview).

.EXAMPLE
    ./deploy-managed-cleanroom.ps1 `
        -resourceGroup cr-collab-rg -collaborationName collab1 `
        -ownerIdentifier woodgrove@contoso.com -resourceLocation westus
#>
param(
    [Parameter(Mandatory)]
    [string]$resourceGroup,

    [Parameter(Mandatory)]
    [string]$collaborationName,

    [string]$rpLocation = "westus",

    [ValidateSet(
        "centralindia", "eastasia", "eastus", "eastus2", "germanywestcentral",
        "italynorth", "japaneast", "northeurope", "southcentralus",
        "southeastasia", "switzerlandnorth", "uaenorth", "westeurope",
        "westus", "westus2")]
    [string]$resourceLocation = "westus",

    [Parameter(Mandatory)]
    [string]$ownerIdentifier,

    [string[]]$additionalCollaborators = @(),

    [string]$workloadType = "Analytics",

    [string]$apiVersion = "2026-04-30-preview",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$armEndpoint = "https://management.azure.com"

$account = az account show -o json | ConvertFrom-Json
$subscription = $account.id
$collabArmUrl = "$armEndpoint/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.CleanRoom/Collaborations/$collaborationName"

if ($DryRun) {
    Write-Host "[DRY-RUN] Would ensure resource group '$resourceGroup' ($rpLocation) and register providers."
    Write-Host "[DRY-RUN] Would deploy Bicep: $PSScriptRoot/managed-cleanroom.bicep"
    Write-Host "[DRY-RUN]   collaborationName=$collaborationName rpLocation=$rpLocation resourceLocation=$resourceLocation"
    Write-Host "[DRY-RUN]   collaborators=[{`"userIdentifier`":`"$ownerIdentifier`"}]"
    Write-Host "[DRY-RUN] Would POST $collabArmUrl/enableWorkload  body {workloadType=$workloadType}"
    foreach ($collaborator in $additionalCollaborators) {
        Write-Host "[DRY-RUN] Would POST $collabArmUrl/addCollaborator  body {collaborator.userIdentifier=$collaborator}"
    }
    Write-Host "[DRY-RUN] Tip: for a real ARM preview run 'az deployment group what-if' (needs an allow-listed subscription)."
    return
}

# ---------------------------------------------------------------------------
# 0. Ensure resource group + providers
# ---------------------------------------------------------------------------
Write-Host "Ensuring resource group '$resourceGroup' ($rpLocation)..."
az group create --name $resourceGroup --location $rpLocation -o none

Write-Host "Registering resource providers (idempotent)..."
az provider register --namespace Microsoft.CleanRoom -o none
az provider register --namespace Microsoft.ContainerService -o none

# ---------------------------------------------------------------------------
# 1. Deploy the collaboration (declarative -- Bicep)
# ---------------------------------------------------------------------------
Write-Host "Deploying collaboration '$collaborationName' via Bicep (~25 min)..."
$deployment = az deployment group create `
    --resource-group $resourceGroup `
    --name "deploy-$collaborationName" `
    --template-file "$PSScriptRoot/managed-cleanroom.bicep" `
    --parameters `
        collaborationName=$collaborationName `
        rpLocation=$rpLocation `
        resourceLocation=$resourceLocation `
        collaborators="[{`"userIdentifier`":`"$ownerIdentifier`"}]" `
    -o json | ConvertFrom-Json

$collabId = $deployment.properties.outputs.collaborationId.value
Write-Host "Collaboration resource ready: $collabId"

# Poll provisioningState to Succeeded (Bicep returns when ARM accepts; infra
# provisioning continues asynchronously).
do {
    $collab = az rest --method GET --url "$collabArmUrl`?api-version=$apiVersion" --resource $armEndpoint -o json | ConvertFrom-Json
    $state = $collab.properties.provisioningState
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] provisioningState: $state"
    if ($state -notin @("Succeeded", "Failed")) { Start-Sleep -Seconds 60 }
} while ($state -notin @("Succeeded", "Failed"))

if ($state -eq "Failed") { throw "Collaboration provisioning failed." }

# ---------------------------------------------------------------------------
# 2. Enable the workload (ARM *action* -- no Bicep equivalent)
# ---------------------------------------------------------------------------
Write-Host "Enabling '$workloadType' workload (~7 min)..."
$enableBody = @{ workloadType = $workloadType } | ConvertTo-Json
[System.IO.File]::WriteAllText("$PWD/body.json", $enableBody)
az rest --method POST `
    --url "$collabArmUrl/enableWorkload`?api-version=$apiVersion" `
    --resource $armEndpoint `
    --headers "Content-Type=application/json" `
    --body "@body.json" -o none

# Poll until the workload endpoint is populated.
do {
    $collab = az rest --method GET --url "$collabArmUrl`?api-version=$apiVersion" --resource $armEndpoint -o json | ConvertFrom-Json
    $wl = $collab.properties.workloads | Where-Object { $_.workloadType -eq $workloadType }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] provisioningState: $($collab.properties.provisioningState) | workload endpoint: $($wl.endpoint)"
    if (-not $wl.endpoint -and $collab.properties.provisioningState -ne "Failed") { Start-Sleep -Seconds 30 }
} while (-not $wl.endpoint -and $collab.properties.provisioningState -ne "Failed")

# Wait for healthState = Ok.
do {
    $collab = az rest --method GET --url "$collabArmUrl`?api-version=$apiVersion" --resource $armEndpoint -o json | ConvertFrom-Json
    $health = $collab.properties.health.healthState
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] healthState: $health"
    if ($health -ne "Ok" -and $collab.properties.health.healthIssues) {
        $collab.properties.health.healthIssues | ForEach-Object { Write-Host "  Issue: $($_ | ConvertTo-Json -Compress)" }
    }
    if ($health -ne "Ok") { Start-Sleep -Seconds 30 }
} while ($health -ne "Ok")

# ---------------------------------------------------------------------------
# 3. Add additional collaborators (ARM *action* -- no Bicep equivalent)
# ---------------------------------------------------------------------------
foreach ($collaborator in $additionalCollaborators) {
    Write-Host "Adding collaborator '$collaborator'..."
    $addBody = @{ collaborator = @{ userIdentifier = $collaborator } } | ConvertTo-Json
    [System.IO.File]::WriteAllText("$PWD/body.json", $addBody)
    az rest --method POST `
        --url "$collabArmUrl/addCollaborator`?api-version=$apiVersion" `
        --resource $armEndpoint `
        --headers "Content-Type=application/json" `
        --body "@body.json" -o none
}

Remove-Item "$PWD/body.json" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Collaboration '$collaborationName' is provisioned and healthy."
Write-Host "Next: follow README-API.md Steps 03-12 (accept invitation, OIDC,"
Write-Host "publish datasets/queries, vote, run) using the frontend REST API."
