#Requires -Version 7.0
<#
.SYNOPSIS
    Grant a service principal the billing role it needs to create subscriptions
    (EA "SubscriptionCreator" or MCA "Azure subscription creator").

.DESCRIPTION
    Run this ONCE, locally, signed in as a human who is an OWNER on the billing
    account / enrollment. It is the single fiddliest step in the whole setup and the
    usual reason subscription creation fails with HTTP 403.

    PowerShell + Az.Accounts only - no Azure CLI, so it runs on a locked-down machine.

    It does NOT hardcode role GUIDs. Instead it LISTS the role definitions that exist
    at your billing scope and matches by name, because the ids differ between
    agreement types and enrollment vintages. If the role cannot be found or the grant
    is refused, it prints the roles that DO exist plus the exact portal steps - which
    is important, because many EA enrollments block billing-role writes over the API
    entirely and can only be changed in the EA portal.

    This script WRITES one role assignment. Nothing else. It creates no subscription
    and touches no Azure resource.

.PARAMETER BillingScope
    EA  /providers/Microsoft.Billing/billingAccounts/{ba}/enrollmentAccounts/{ea}
    MCA /providers/Microsoft.Billing/billingAccounts/{ba}/billingProfiles/{bp}/invoiceSections/{is}

.PARAMETER ApplicationId
    The service principal's application (client) id. The object id is looked up.

.PARAMETER ObjectId
    The service principal's OBJECT id, if you already know it. Skips the lookup and
    removes the need for any Microsoft Graph permission.

.PARAMETER WhatIf
    Show what would be granted, change nothing.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-guid>
    ./Grant-SubscriptionCreatorRole.ps1 `
        -BillingScope '/providers/Microsoft.Billing/billingAccounts/12345678/enrollmentAccounts/98765' `
        -ApplicationId '00000000-1111-2222-3333-444444444444'

.NOTES
    Verify afterwards with:  New-AzureSubscription.ps1 ... -PreflightOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $BillingScope,
    [string] $ApplicationId,
    [string] $ObjectId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$API = '2019-10-01-preview'

function Write-Head { param([string] $T) Write-Host ''; Write-Host "== $T" -ForegroundColor Cyan }
function Write-Ok   { param([string] $M) Write-Host "   [ ok ] $M" -ForegroundColor Green }
function Write-Info { param([string] $M) Write-Host "   [info] $M" }
function Write-Warn { param([string] $M) Write-Host "   [warn] $M" -ForegroundColor Yellow }

function Invoke-Arm {
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet('GET', 'PUT', 'POST')][string] $Method = 'GET',
        [string] $Payload
    )
    # Invoke-AzRestMethod takes -Path for ARM-relative calls but needs -Uri for an
    # absolute URL (e.g. Microsoft Graph), which also selects the right token audience.
    if ($Path -match '^https://') { $splat = @{ Uri = $Path; Method = $Method } }
    else                          { $splat = @{ Path = $Path; Method = $Method } }
    if ($Payload) { $splat.Payload = $Payload }
    try { $resp = Invoke-AzRestMethod @splat }
    catch { return [pscustomobject]@{ Ok = $false; StatusCode = 0; Content = $_.Exception.Message; Json = $null } }
    $json = $null
    if ($resp.Content) { try { $json = $resp.Content | ConvertFrom-Json -Depth 40 } catch { $json = $null } }
    [pscustomobject]@{
        Ok = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300)
        StatusCode = $resp.StatusCode; Content = $resp.Content; Json = $json
    }
}

if (-not $ApplicationId -and -not $ObjectId) {
    throw 'Pass -ApplicationId or -ObjectId.'
}

switch -Wildcard ($BillingScope) {
    '*/enrollmentAccounts/*' { $agreement = 'EA';  $wantedRole = 'SubscriptionCreator' }
    '*/invoiceSections/*'    { $agreement = 'MCA'; $wantedRole = 'Azure subscription creator' }
    '*/customers/*'          { $agreement = 'MPA'; $wantedRole = 'Azure subscription creator' }
    default {
        throw @"
Unrecognised billing scope: $BillingScope
Expected one of:
  EA   /providers/Microsoft.Billing/billingAccounts/{ba}/enrollmentAccounts/{ea}
  MCA  /providers/Microsoft.Billing/billingAccounts/{ba}/billingProfiles/{bp}/invoiceSections/{is}
  MPA  /providers/Microsoft.Billing/billingAccounts/{ba}/customers/{c}
"@
    }
}

Write-Head 'Context'
Write-Info "agreement   : $agreement"
Write-Info "wanted role : $wantedRole"
Write-Info "scope       : $BillingScope"

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Info 'installing Az.Accounts for the current user (no admin rights needed)'
    Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
}
Import-Module Az.Accounts -ErrorAction Stop

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Azure context. Run Connect-AzAccount -Tenant <tenant-guid> first.' }
Write-Ok "signed in as $($ctx.Account.Id) (tenant $($ctx.Tenant.Id))"
$tenantId = $ctx.Tenant.Id

# ---------------------------------------------------- resolve the principal ----
if (-not $ObjectId) {
    Write-Head 'Resolve service principal'
    $spRes = Invoke-Arm -Path "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$ApplicationId')"
    if ($spRes.Ok -and $spRes.Json -and $spRes.Json.PSObject.Properties.Name -contains 'id') {
        $ObjectId = $spRes.Json.id
        $dn = if ($spRes.Json.PSObject.Properties.Name -contains 'displayName') { $spRes.Json.displayName } else { '' }
        Write-Ok "object id $ObjectId  ($dn)"
    } else {
        throw @"
Could not resolve the service principal for application id '$ApplicationId'.
Either your account cannot read service principals, or the app id is wrong.
Find the object id in the portal (Entra ID > Enterprise applications > your app >
Object ID) and pass it with -ObjectId instead.
"@
    }
}

# ------------------------------------------------- find the role definition ----
Write-Head 'Find the role definition at this scope'

$defsRes = Invoke-Arm -Path "$BillingScope/billingRoleDefinitions?api-version=$API"
if (-not $defsRes.Ok) {
    Write-Warn "cannot list role definitions (HTTP $($defsRes.StatusCode))."
    Write-Warn 'You are probably not an owner on this billing scope, or the enrollment blocks API access.'
    Write-Warn 'Use the portal route printed at the end.'
}

$roleDefId = $null
$available = @()
if ($defsRes.Ok -and $defsRes.Json -and $defsRes.Json.PSObject.Properties.Name -contains 'value') {
    foreach ($d in $defsRes.Json.value) {
        if ($d.PSObject.Properties.Name -notcontains 'properties') { continue }
        $name = if ($d.properties.PSObject.Properties.Name -contains 'roleName') { $d.properties.roleName } else { '' }
        if ($name) { $available += $name }
        # Match loosely: EA shows "SubscriptionCreator", MCA "Azure subscription creator".
        if ($name -and ($name -replace '\s', '') -ieq ($wantedRole -replace '\s', '')) { $roleDefId = $d.id }
    }
}

if ($available) { Write-Info "roles available here: $($available -join ', ')" }

if (-not $roleDefId) {
    Write-Warn "role '$wantedRole' was not found at this scope."
    if ($available) { Write-Warn "What DOES exist: $($available -join ', ')" }
    Write-Host ''
    Write-Host '   Grant it in the portal instead:' -ForegroundColor Yellow
    if ($agreement -eq 'EA') {
        Write-Host '     EA portal (ea.azure.com) or Cost Management + Billing > your enrollment' -ForegroundColor Yellow
        Write-Host '       > Enrollment account > + Add > role "Subscription creator"' -ForegroundColor Yellow
        Write-Host '       > search for the SERVICE PRINCIPAL by its application id' -ForegroundColor Yellow
        Write-Host '     Many enrollments only accept this change in the portal, never over the API.' -ForegroundColor Yellow
    } else {
        Write-Host '     Cost Management + Billing > Billing profile > Invoice sections' -ForegroundColor Yellow
        Write-Host '       > your invoice section > Access control (IAM) > + Add' -ForegroundColor Yellow
        Write-Host '       > role "Azure subscription creator" > select the service principal' -ForegroundColor Yellow
    }
    exit 1
}
Write-Ok "role definition: $roleDefId"

# -------------------------------------------------------------- assign it -----
Write-Head 'Assign'

if (-not $PSCmdlet.ShouldProcess("$BillingScope", "grant '$wantedRole' to principal $ObjectId")) {
    Write-Info 'WhatIf - nothing was changed.'
    exit 0
}

# EA and MCA create billing role assignments through DIFFERENT operations, and
# using the wrong one surfaces as a confusing AuthorizationFailed rather than a
# clean "method not supported":
#   EA  -> PUT  {scope}/billingRoleAssignments/{guid}   (body wrapped in properties)
#   MCA -> POST {scope}/createBillingRoleAssignment     (flat body)
# Try the one matching the agreement first, then fall back to the other, since
# support varies by billing account vintage.
$assignmentName = [guid]::NewGuid().ToString()

$putBody = @{
    properties = [ordered]@{
        principalId       = $ObjectId
        principalTenantId = $tenantId
        roleDefinitionId  = $roleDefId
    }
} | ConvertTo-Json -Depth 6

$postBody = [ordered]@{
    principalId       = $ObjectId
    principalTenantId = $tenantId
    roleDefinitionId  = $roleDefId
} | ConvertTo-Json -Depth 6

$putAttempt  = @{ label = 'PUT billingRoleAssignments';       method = 'PUT';  path = "$BillingScope/billingRoleAssignments/$assignmentName`?api-version=$API"; body = $putBody }
$postAttempt = @{ label = 'POST createBillingRoleAssignment'; method = 'POST'; path = "$BillingScope/createBillingRoleAssignment`?api-version=$API";            body = $postBody }

$attempts = if ($agreement -eq 'EA') { @($putAttempt, $postAttempt) } else { @($postAttempt, $putAttempt) }

$put = $null
foreach ($attempt in $attempts) {
    Write-Info "trying: $($attempt.label)"
    $put = Invoke-Arm -Method $attempt.method -Path $attempt.path -Payload $attempt.body
    if ($put.Ok -or $put.StatusCode -eq 409) { break }
    Write-Info "  -> HTTP $($put.StatusCode)"
}

if ($put.Ok) {
    Write-Ok "granted '$wantedRole' to $ObjectId"
    Write-Host ''
    Write-Host '   Role assignments on a billing scope can take a few minutes to take effect.' -ForegroundColor Green
    Write-Host '   Verify with:  New-AzureSubscription.ps1 ... -PreflightOnly' -ForegroundColor Green
    exit 0
}

# 409 usually means "already assigned" - treat as success, it is what we wanted.
if ($put.StatusCode -eq 409) {
    Write-Ok 'already assigned (HTTP 409) - nothing to do'
    exit 0
}

Write-Warn "grant failed (HTTP $($put.StatusCode)): $(($put.Content -replace '\s+', ' ').Trim())"
Write-Host ''

# A 403 here is about the SIGNED-IN USER, not the service principal: listing role
# definitions is a read, assigning one is a write, and they are separate billing
# permissions. Say so, because the message otherwise reads like the SP was refused.
if ($put.StatusCode -eq 403) {
    Write-Host '   HTTP 403 means YOUR OWN account cannot assign roles at this scope.' -ForegroundColor Yellow
    Write-Host '   The service principal was never evaluated - the request stopped at your permission.' -ForegroundColor Yellow
    Write-Host ''
    if ($agreement -eq 'EA') {
        Write-Host '   You need Enrollment Account Owner (or EA Administrator) on the enrollment.' -ForegroundColor Yellow
    } else {
        Write-Host '   You need Invoice section owner, Billing profile owner, or Billing account owner.' -ForegroundColor Yellow
        Write-Host '   Invoice section READER can list roles but cannot assign them - that is this error.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '   Check what you actually hold:' -ForegroundColor Yellow
    Write-Host "     Invoke-AzRestMethod -Method GET -Path '$BillingScope/billingRoleAssignments?api-version=$API'" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   NOTE: the portal uses this same API, so it will fail the same way until' -ForegroundColor Yellow
    Write-Host '   your own billing access is raised. Ask whoever owns the billing account.' -ForegroundColor Yellow
    Write-Host ''
}

Write-Host '   Portal route (once you have the access above):' -ForegroundColor Yellow
if ($agreement -eq 'EA') {
    Write-Host '     Cost Management + Billing > your enrollment > Enrollment account' -ForegroundColor Yellow
    Write-Host '       > + Add > "Subscription creator" > pick the service principal by application id' -ForegroundColor Yellow
} else {
    Write-Host '     Cost Management + Billing > Billing profile > Invoice sections > your section' -ForegroundColor Yellow
    Write-Host '       > Access control (IAM) > + Add > "Azure subscription creator"' -ForegroundColor Yellow
}
exit 1
