#Requires -Version 7.0
<#
.SYNOPSIS
    Create ONE Azure subscription (EA or MCA) and place it directly into a target
    management group.

.DESCRIPTION
    Deliberately standalone: no Terraform, no state, no dependency on any other
    file. It talks to the Azure REST API through the
    Az.Accounts module only — there is NO Azure CLI dependency, so it runs on a
    locked-down workstation as happily as on a GitHub runner.

    WHAT IT DOES, IN ORDER
      1. Sign in            OIDC federated token when run in GitHub Actions, or an
                            existing Connect-AzAccount session when run locally.
      2. Preflight (READ-ONLY)
                            - billing scope is readable, and its agreement type
                            - which billing roles the identity actually holds
                            - target management group exists and is readable
                            - the alias name is FREE  <-- the important one
                            - warn on a display-name collision
      3. Create             PUT the subscription alias, with the management group
                            supplied in the same call so the subscription lands in
                            the right place immediately.
      4. Poll               until the alias reaches a terminal provisioning state.
      5. Verify             confirm the subscription really is under the target MG,
                            and place it explicitly if the alias did not.

    WHY THE ALIAS CHECK MATTERS
    A subscription alias is a TENANT-LEVEL, IMMUTABLE name binding that OUTLIVES the
    subscription it created. Cancel a subscription and its alias remains. Reuse that
    alias name later and Azure silently hands back the OLD, CANCELLED subscription
    with HTTP 200 instead of creating a new one — no error, no warning, and you only
    notice when deployments target a dead subscription. So this script refuses to
    proceed if the alias already exists, and tells you how to clear it.

.PARAMETER DisplayName
    Subscription display name as it appears in the portal. Required.

.PARAMETER BillingScope
    The billing scope to charge. Required. The agreement type is detected from its shape:
      EA  /providers/Microsoft.Billing/billingAccounts/{ba}/enrollmentAccounts/{ea}
      MCA /providers/Microsoft.Billing/billingAccounts/{ba}/billingProfiles/{bp}/invoiceSections/{is}
      MPA /providers/Microsoft.Billing/billingAccounts/{ba}/customers/{c}

.PARAMETER ManagementGroupId
    Target management group. Accepts the bare id ("landingzones") or a full
    resource id. The subscription is placed here at creation time.

.PARAMETER AliasName
    Alias resource name. Defaults to a sanitised form of DisplayName.
    Permanent and tenant-unique — see the warning above.

.PARAMETER Workload
    Production (default) or DevTest. DevTest requires an eligible billing scope.

.PARAMETER Tags
    Tags as "key=value,key=value".

.PARAMETER PreflightOnly
    Run every read-only check and STOP. Creates nothing. Costs nothing.

.PARAMETER UseExistingContext
    Use the current Connect-AzAccount session instead of GitHub OIDC. Implied when
    the GitHub OIDC environment variables are absent.

.EXAMPLE
    # Local dry run — read-only, proves permissions without spending anything
    Connect-AzAccount -Tenant <tenant-guid>
    ./New-AzureSubscription.ps1 -DisplayName 'Payments UK (dev)' `
        -BillingScope '/providers/Microsoft.Billing/billingAccounts/12345678/enrollmentAccounts/98765' `
        -ManagementGroupId 'landingzones' -PreflightOnly

.EXAMPLE
    # For real
    ./New-AzureSubscription.ps1 -DisplayName 'Payments UK (dev)' `
        -BillingScope '/providers/Microsoft.Billing/billingAccounts/12345678/enrollmentAccounts/98765' `
        -ManagementGroupId 'uk-payments-dev' -Workload DevTest -Tags 'env=dev,owner=platform'

.NOTES
    Modules : Az.Accounts (only). Installed on demand, CurrentUser scope, no admin.
    Rights  : EA  -> SubscriptionCreator on the enrollment account
              MCA -> "Azure subscription creator" on the invoice section
              plus write access on the target management group.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DisplayName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $BillingScope,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ManagementGroupId,

    [string] $AliasName,
    [ValidateSet('Production', 'DevTest')][string] $Workload = 'Production',
    [string] $Tags,

    [switch] $PreflightOnly,
    [switch] $UseExistingContext,

    [string] $ClientId       = $env:AZURE_CLIENT_ID,
    [string] $TenantId       = $env:AZURE_TENANT_ID,
    [string] $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID,

    [ValidateRange(1, 120)][int] $TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ALIAS_API = '2021-10-01'
$MG_API    = '2021-04-01'
# Billing scopes are readable under different api-versions depending on agreement
# type and how old the enrollment is. Try newest first and take whatever answers.
$BILLING_APIS = @('2020-05-01', '2019-10-01-preview', '2019-10-01')

# ------------------------------------------------------------------ output ----
$script:Failures = @()
function Write-Head { param([string] $T) Write-Host ''; Write-Host "== $T" -ForegroundColor Cyan }
function Write-Ok   { param([string] $M) Write-Host "   [ ok ] $M" -ForegroundColor Green }
function Write-Info { param([string] $M) Write-Host "   [info] $M" }
function Write-Warn { param([string] $M) Write-Host "   [warn] $M" -ForegroundColor Yellow }
function Write-Fail { param([string] $M) Write-Host "   [FAIL] $M" -ForegroundColor Red; $script:Failures += $M }

# GitHub Actions step summary / outputs. No-ops outside Actions.
function Add-Summary { param([string] $Line)
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Line }
}
function Set-Output { param([string] $Name, [string] $Value)
    if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value" }
}

# -------------------------------------------------------------- REST helper ----
# Never throws on an HTTP error: callers branch on StatusCode. A preflight check
# that blew up on the first 403 would hide every later finding.
function Invoke-Arm {
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet('GET', 'PUT', 'POST', 'DELETE')][string] $Method = 'GET',
        [string] $Payload
    )
    $splat = @{ Path = $Path; Method = $Method }
    if ($Payload) { $splat.Payload = $Payload }
    try {
        $resp = Invoke-AzRestMethod @splat
    } catch {
        return [pscustomobject]@{ Ok = $false; StatusCode = 0; Content = $_.Exception.Message; Json = $null }
    }
    $json = $null
    if ($resp.Content) { try { $json = $resp.Content | ConvertFrom-Json -Depth 40 } catch { $json = $null } }
    [pscustomobject]@{
        Ok         = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300)
        StatusCode = $resp.StatusCode
        Content    = $resp.Content
        Json       = $json
    }
}

function Get-ArmError {
    param($Response)
    if ($Response.Json -and $Response.Json.PSObject.Properties.Name -contains 'error') {
        $e = $Response.Json.error
        $code = if ($e.PSObject.Properties.Name -contains 'code') { $e.code } else { '?' }
        $msg  = if ($e.PSObject.Properties.Name -contains 'message') { $e.message } else { '' }
        return "$code - $msg"
    }
    if ($Response.Content) { return ($Response.Content -replace '\s+', ' ').Trim() }
    return "HTTP $($Response.StatusCode)"
}

# ------------------------------------------------------------ normalisation ----
function ConvertTo-AliasName {
    param([string] $From)
    $a = $From.ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-+', '-'
    $a = $a.Trim('-')
    if ($a.Length -gt 60) { $a = $a.Substring(0, 60).Trim('-') }
    if (-not $a) { $a = 'subscription' }
    return $a
}

function ConvertTo-TagHashtable {
    param([string] $From)
    $h = @{}
    if (-not $From) { return $h }
    foreach ($pair in $From.Split(',')) {
        $kv = $pair.Split('=', 2)
        if ($kv.Count -eq 2 -and $kv[0].Trim()) { $h[$kv[0].Trim()] = $kv[1].Trim() }
        elseif ($pair.Trim())                   { Write-Warn "ignoring malformed tag '$($pair.Trim())' (expected key=value)" }
    }
    return $h
}

# Accept "landingzones" or a full /providers/... resource id; return both forms.
$mgName = $ManagementGroupId
if ($mgName -match '/managementGroups/([^/]+)/?$') { $mgName = $Matches[1] }
$mgName = $mgName.Trim('/')
$mgFullId = "/providers/Microsoft.Management/managementGroups/$mgName"

if (-not $AliasName) { $AliasName = ConvertTo-AliasName -From $DisplayName }
if ($AliasName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') {
    throw "AliasName '$AliasName' is not valid. Use 1-63 chars: letters, digits, dot, underscore, hyphen; must start alphanumeric."
}

switch -Wildcard ($BillingScope) {
    '*/enrollmentAccounts/*' { $agreement = 'EA';  $expectedRole = 'SubscriptionCreator (or Enrollment Account Owner)' }
    '*/invoiceSections/*'    { $agreement = 'MCA'; $expectedRole = 'Azure subscription creator' }
    '*/customers/*'          { $agreement = 'MPA'; $expectedRole = 'Azure subscription creator' }
    default                  { $agreement = 'UNKNOWN'; $expectedRole = '(unrecognised billing scope shape)' }
}

Write-Head 'Request'
Write-Info "display name  : $DisplayName"
Write-Info "alias         : $AliasName"
Write-Info "management grp: $mgName"
Write-Info "agreement     : $agreement"
Write-Info "workload      : $Workload"
Write-Info "mode          : $(if ($PreflightOnly) { 'PREFLIGHT ONLY - nothing will be created' } else { 'CREATE' })"
if ($agreement -eq 'UNKNOWN') {
    Write-Warn 'Billing scope shape not recognised. Creation will probably fail — check the value against the examples in the README.'
}

# --------------------------------------------------------------- sign in ------
Write-Head 'Sign in'

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Info 'Az.Accounts not present — installing for the current user (no admin rights needed)'
    Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
}
Import-Module Az.Accounts -ErrorAction Stop

$inActions = [bool]($env:ACTIONS_ID_TOKEN_REQUEST_URL -and $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)

if ($UseExistingContext -or -not $inActions) {
    $ctx = Get-AzContext
    if (-not $ctx) {
        throw 'No Azure context. Run Connect-AzAccount first, or run this inside GitHub Actions with id-token: write.'
    }
    Write-Ok "using existing context: $($ctx.Account.Id) (tenant $($ctx.Tenant.Id))"
} else {
    if (-not $ClientId -or -not $TenantId) {
        throw 'OIDC sign-in needs AZURE_CLIENT_ID and AZURE_TENANT_ID (repo variables).'
    }
    Write-Info "requesting a GitHub OIDC token for audience api://AzureADTokenExchange"
    $tokenUri = "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=api%3A%2F%2FAzureADTokenExchange"
    $idToken = (Invoke-RestMethod -Uri $tokenUri -Headers @{
        Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)"
    }).value

    $connect = @{
        ServicePrincipal = $true
        ApplicationId    = $ClientId
        Tenant           = $TenantId
        FederatedToken   = $idToken
    }
    if ($SubscriptionId) { $connect.Subscription = $SubscriptionId }
    $null = Connect-AzAccount @connect
    Write-Ok "signed in via OIDC as app $ClientId"
}

$ctx = Get-AzContext
if (-not $ctx.Subscription -or -not $ctx.Subscription.Id) {
    # Tenant-level REST calls still need *a* subscription in context.
    $anySub = Get-AzSubscription -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($anySub) { $null = Set-AzContext -SubscriptionId $anySub.Id; Write-Info "context subscription set to $($anySub.Id)" }
    else { Write-Warn 'No subscription in context. Tenant-level calls may fail.' }
}

# ------------------------------------------------------------- preflight ------
Write-Head 'Preflight (read-only)'

# 1. Billing scope readable?
$billingOk = $false
foreach ($api in $BILLING_APIS) {
    $r = Invoke-Arm -Path "$BillingScope`?api-version=$api"
    if ($r.Ok) { Write-Ok "billing scope readable (api-version $api)"; $billingOk = $true; break }
    if ($r.StatusCode -eq 403) { Write-Warn "billing scope returned 403 on api-version $api"; break }
}
if (-not $billingOk) {
    # Not fatal on EA: many enrollments deny reads to an SP that can still create.
    Write-Warn "could not read the billing scope. Expected role: $expectedRole"
    Write-Warn 'On EA this is common and does NOT always mean creation will fail — the read and create permissions are separate.'
}

# 2. Which billing roles does this identity hold? Informational only.
$roleRes = Invoke-Arm -Path "$BillingScope/billingRoleAssignments?api-version=2019-10-01-preview"
if ($roleRes.Ok -and $roleRes.Json -and $roleRes.Json.PSObject.Properties.Name -contains 'value') {
    $names = foreach ($ra in $roleRes.Json.value) {
        if ($ra.PSObject.Properties.Name -contains 'properties') {
            $p = $ra.properties
            if ($p.PSObject.Properties.Name -contains 'roleDefinitionName') { $p.roleDefinitionName }
            elseif ($p.PSObject.Properties.Name -contains 'roleDefinitionId') { ($p.roleDefinitionId -split '/')[-1] }
        }
    }
    $names = @($names | Where-Object { $_ } | Sort-Object -Unique)
    if ($names) { Write-Info "billing roles visible on this scope: $($names -join ', ')" }
    else        { Write-Info 'no billing role assignments returned (the API may hide them from a service principal)' }
} else {
    Write-Info 'billing role assignments not listable — skipping (normal for many EA enrollments)'
}

# 3. Target management group reachable?
$mgRes = Invoke-Arm -Path "$mgFullId`?api-version=$MG_API"
if ($mgRes.Ok) {
    $dn = $mgName
    if ($mgRes.Json -and $mgRes.Json.PSObject.Properties.Name -contains 'properties' -and
        $mgRes.Json.properties.PSObject.Properties.Name -contains 'displayName') { $dn = $mgRes.Json.properties.displayName }
    Write-Ok "management group '$mgName' exists ($dn)"
} elseif ($mgRes.StatusCode -eq 404) {
    Write-Fail "management group '$mgName' does not exist. Create it first, or correct -ManagementGroupId."
} else {
    Write-Fail "cannot read management group '$mgName': $(Get-ArmError $mgRes)"
}

# 4. Is the alias name free? THE trap — see the header notes.
$aliasRes = Invoke-Arm -Path "/providers/Microsoft.Subscription/aliases/$AliasName`?api-version=$ALIAS_API"
if ($aliasRes.StatusCode -eq 404) {
    Write-Ok "alias '$AliasName' is free"
} elseif ($aliasRes.Ok) {
    $existingSub = '(unknown)'
    if ($aliasRes.Json -and $aliasRes.Json.PSObject.Properties.Name -contains 'properties' -and
        $aliasRes.Json.properties.PSObject.Properties.Name -contains 'subscriptionId') {
        $existingSub = $aliasRes.Json.properties.subscriptionId
    }
    Write-Fail "alias '$AliasName' ALREADY EXISTS and points at subscription $existingSub."
    Write-Fail 'Reusing it would silently return that existing (possibly cancelled) subscription instead of creating a new one.'
    Write-Fail "Fix: choose a different -AliasName, or delete the old alias once you are certain it is not needed:"
    Write-Fail "  Invoke-AzRestMethod -Method DELETE -Path '/providers/Microsoft.Subscription/aliases/$AliasName`?api-version=$ALIAS_API'"
    Write-Fail '  (deleting an alias does NOT delete or cancel the subscription it points to)'
} else {
    Write-Warn "could not check the alias: $(Get-ArmError $aliasRes)"
}

# 5. Display-name collision — a warning, never a blocker. Azure permits duplicates.
try {
    $clash = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $DisplayName }
    if ($clash) {
        Write-Warn "a subscription named '$DisplayName' already exists ($($clash.Id -join ', ')). Azure allows duplicate display names — make sure this is intended."
    }
} catch { Write-Info 'display-name check skipped (cannot list subscriptions)' }

if ($script:Failures.Count -gt 0) {
    Write-Head 'Result'
    Write-Host '   PREFLIGHT FAILED — nothing was created.' -ForegroundColor Red
    Add-Summary "## Subscription creation: preflight FAILED`n"
    foreach ($f in $script:Failures) { Add-Summary "- $f" }
    exit 1
}

Write-Ok 'all preflight checks passed'

if ($PreflightOnly) {
    Write-Head 'Result'
    Write-Host '   PREFLIGHT ONLY — no subscription was created.' -ForegroundColor Yellow
    Add-Summary "## Subscription creation: preflight passed`n"
    Add-Summary "Nothing was created (preflight-only mode)."
    Add-Summary "`n| Field | Value |`n|---|---|"
    Add-Summary "| Display name | $DisplayName |"
    Add-Summary "| Alias | $AliasName |"
    Add-Summary "| Management group | $mgName |"
    Add-Summary "| Agreement | $agreement |"
    Set-Output -Name 'preflight' -Value 'passed'
    exit 0
}

# ---------------------------------------------------------------- create ------
Write-Head 'Create subscription'

$props = [ordered]@{
    displayName  = $DisplayName
    workload     = $Workload
    billingScope = $BillingScope
    additionalProperties = [ordered]@{
        managementGroupId = $mgFullId
    }
}
$tagHash = ConvertTo-TagHashtable -From $Tags
if ($tagHash.Count -gt 0) {
    $props.additionalProperties.tags = $tagHash
    Write-Info "tags: $(($tagHash.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
}
$body = @{ properties = $props } | ConvertTo-Json -Depth 10

Write-Info "PUT /providers/Microsoft.Subscription/aliases/$AliasName"
$create = Invoke-Arm -Method PUT -Path "/providers/Microsoft.Subscription/aliases/$AliasName`?api-version=$ALIAS_API" -Payload $body

if (-not $create.Ok) {
    Write-Fail "subscription creation was rejected: $(Get-ArmError $create)"
    switch ($create.StatusCode) {
        401 { Write-Fail 'HTTP 401 — the OIDC sign-in did not produce a usable token.' }
        403 { Write-Fail "HTTP 403 — the identity lacks '$expectedRole' on the billing scope. See the README, 'Grant the billing role'." }
        400 { Write-Fail 'HTTP 400 — check the billing scope value, and that the billing account has subscription-creation quota left.' }
        429 { Write-Fail 'HTTP 429 — throttled by the billing API. Wait a few minutes and retry.' }
    }
    Add-Summary "## Subscription creation FAILED`n`n``$(Get-ArmError $create)``"
    exit 1
}
Write-Ok "accepted (HTTP $($create.StatusCode))"

# ------------------------------------------------------------------ poll ------
Write-Head 'Wait for provisioning'

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$newSubId = $null
$state    = 'Unknown'
$delay    = 10

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $delay
    $poll = Invoke-Arm -Path "/providers/Microsoft.Subscription/aliases/$AliasName`?api-version=$ALIAS_API"
    if (-not $poll.Ok) { Write-Info "poll returned HTTP $($poll.StatusCode) — retrying"; continue }

    $p = $poll.Json.properties
    $state = if ($p.PSObject.Properties.Name -contains 'provisioningState') { $p.provisioningState } else { 'Unknown' }
    if ($p.PSObject.Properties.Name -contains 'subscriptionId' -and $p.subscriptionId) { $newSubId = $p.subscriptionId }
    Write-Info "provisioningState = $state$(if ($newSubId) { "  subscriptionId = $newSubId" })"

    if ($state -in @('Succeeded', 'Failed', 'Canceled')) { break }
    if ($delay -lt 30) { $delay += 5 }   # ease off; the billing API throttles hard
}

if ($state -ne 'Succeeded') {
    Write-Fail "provisioning did not succeed (last state: $state)."
    if ($state -eq 'Unknown') { Write-Fail "Timed out after $TimeoutMinutes minutes. The subscription MAY still appear later — check the portal before retrying, and do NOT reuse the alias name blindly." }
    Add-Summary "## Subscription creation FAILED`n`nLast provisioning state: **$state**"
    exit 1
}
if (-not $newSubId) { Write-Fail 'provisioning succeeded but no subscriptionId was returned.'; exit 1 }

Write-Ok "subscription created: $newSubId"

# ---------------------------------------------------------------- verify ------
Write-Head 'Verify management group placement'

$placed = $false
for ($i = 1; $i -le 6; $i++) {
    $check = Invoke-Arm -Path "$mgFullId/subscriptions/$newSubId`?api-version=$MG_API"
    if ($check.Ok) { $placed = $true; break }
    Write-Info "not visible under '$mgName' yet (attempt $i/6) — management group association can lag"
    Start-Sleep -Seconds 10
}

if (-not $placed) {
    Write-Warn "not placed by the alias call — associating explicitly"
    $assoc = Invoke-Arm -Method PUT -Path "$mgFullId/subscriptions/$newSubId`?api-version=$MG_API"
    if ($assoc.Ok) { Write-Ok "associated with '$mgName'"; $placed = $true }
    else {
        Write-Warn "explicit association failed: $(Get-ArmError $assoc)"
        Write-Warn "The SUBSCRIPTION EXISTS ($newSubId) but sits in the tenant root. Move it manually, or grant the identity write access on '$mgName' and re-run the association."
    }
} else {
    Write-Ok "subscription is under '$mgName'"
}

# ---------------------------------------------------------------- report ------
Write-Head 'Result'
Write-Host "   Subscription ID : $newSubId" -ForegroundColor Green
Write-Host "   Display name    : $DisplayName" -ForegroundColor Green
Write-Host "   Alias           : $AliasName" -ForegroundColor Green
Write-Host "   Management group: $mgName$(if (-not $placed) { '  (NOT PLACED — see above)' })" -ForegroundColor Green

Set-Output -Name 'subscription_id'   -Value $newSubId
Set-Output -Name 'alias_name'        -Value $AliasName
Set-Output -Name 'management_group'  -Value $mgName
Set-Output -Name 'placed'            -Value ([string]$placed)

Add-Summary "## Subscription created`n"
Add-Summary "| Field | Value |"
Add-Summary "|---|---|"
Add-Summary "| Subscription ID | ``$newSubId`` |"
Add-Summary "| Display name | $DisplayName |"
Add-Summary "| Alias | ``$AliasName`` |"
Add-Summary "| Management group | ``$mgName`` |"
Add-Summary "| Agreement | $agreement |"
Add-Summary "| Workload | $Workload |"
Add-Summary "| Placed in MG | $(if ($placed) { 'yes' } else { '**NO — needs a manual move**' }) |"
Add-Summary ""
Add-Summary "> The alias ``$AliasName`` is now permanently bound in this tenant. Cancelling the"
Add-Summary "> subscription does not release it — delete the alias too if you ever want to reuse the name."

exit 0
