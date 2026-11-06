#Requires -Modules Az.Accounts, Az.Automation, Az.Resources
<#
.SYNOPSIS
    Deploys a dedicated Automation account and hourly certificate policy remediation.
.DESCRIPTION
    Run after Connect-AzAccount. Both resource groups must already exist in the
    specified subscription. No policy definition or assignment is created.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [Parameter(Mandatory)] [string] $AutomationResourceGroupName,
    [Parameter(Mandatory)] [string] $AutomationAccountName,
    [Parameter(Mandatory)] [string] $Location,
    [Parameter(Mandatory)] [ValidatePattern('^[^/]+$')] [string] $TargetResourceGroupName,
    [Parameter(Mandatory)]
    [ValidatePattern('(?i)^/subscriptions/[^/]+(/resourceGroups/[^/]+)?/providers/Microsoft.Authorization/policyAssignments/[^/]+$')]
    [string] $PolicyAssignmentId
)

$ErrorActionPreference = 'Stop'
$subscriptionScope = "/subscriptions/$SubscriptionId"
$scope = "$subscriptionScope/resourceGroups/$TargetResourceGroupName"
$assignmentScope = $PolicyAssignmentId -replace '(?i)/providers/Microsoft.Authorization/policyAssignments/[^/]+$', ''
if ($assignmentScope -ine $subscriptionScope -and $assignmentScope -ine $scope) {
    throw 'The assignment must be scoped to the target resource group or its subscription.'
}

Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
Get-AzResourceGroup -Name $AutomationResourceGroupName -ErrorAction Stop | Out-Null
Get-AzResourceGroup -Name $TargetResourceGroupName -ErrorAction Stop | Out-Null
$response = Invoke-AzRestMethod -Method GET -Path "${PolicyAssignmentId}?api-version=2022-06-01" -ErrorAction Stop
if ($response.StatusCode -ne 200) {
    throw "Cannot read policy assignment ($($response.StatusCode)): $($response.Content)"
}
$assignment = $response.Content | ConvertFrom-Json
if ($assignment.properties.policyDefinitionId -notmatch '(?i)/policyDefinitions/[^/]+$') {
    throw 'Supply a standalone policy assignment, not an initiative assignment.'
}
if (-not $assignment.identity -or $assignment.identity.type -eq 'None') {
    throw 'The policy assignment requires a managed identity with extension deployment permissions.'
}
if ($assignment.properties.parameters.effect -and $assignment.properties.parameters.effect.value -ne 'DeployIfNotExists') {
    throw 'The policy assignment effect must be DeployIfNotExists.'
}

$automation = @{ ResourceGroupName = $AutomationResourceGroupName; AutomationAccountName = $AutomationAccountName }
$runbookName = 'Invoke-KvCertRemediation'
$scheduleName = 'KvCertRemediation-Hourly'
$runbookParameters = @{
    SubscriptionId = $SubscriptionId.ToString()
    ResourceGroupName = $TargetResourceGroupName
    PolicyAssignmentId = $PolicyAssignmentId
}

$account = Get-AzAutomationAccount -ResourceGroupName $AutomationResourceGroupName |
    Where-Object { $_.AutomationAccountName -eq $AutomationAccountName }
if (-not $account) {
    $account = New-AzAutomationAccount -ResourceGroupName $AutomationResourceGroupName `
        -Name $AutomationAccountName -Location $Location -Plan Basic -AssignSystemIdentity
}
if (-not $account.Identity.PrincipalId) {
    throw 'The Automation account must have a system-assigned managed identity. Enable it before rerunning.'
}

# This account is dedicated to one assignment and target group.
$links = @(Get-AzAutomationScheduledRunbook @automation | Where-Object { $_.RunbookName -eq $runbookName })
foreach ($link in $links) {
    foreach ($key in $runbookParameters.Keys) {
        $parameterKey = $link.Parameters.Keys | Where-Object { $_ -ieq $key }
        if (-not $parameterKey -or $link.Parameters[$parameterKey] -ine $runbookParameters[$key]) {
            throw "Existing scheduled runbook targets different parameters ($key). Use a separate Automation account."
        }
    }
}

$principalId = $account.Identity.PrincipalId
$roles = @(
    @{ Scope = $scope; Id = '36243c78-bf99-498c-9df9-86d9f8d28608' },
    @{ Scope = $PolicyAssignmentId; Id = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' }
)
foreach ($role in $roles) {
    # Az.Resources scope validation rejects subscription-level policy assignment resources.
    $roleAssignmentsPath = "$($role.Scope)/providers/Microsoft.Authorization/roleAssignments"
    $roleDefinitionId = "$subscriptionScope/providers/Microsoft.Authorization/roleDefinitions/$($role.Id)"
    $filter = [Uri]::EscapeDataString("principalId eq '$principalId'")
    $nextPath = "${roleAssignmentsPath}?api-version=2022-04-01&`$filter=$filter"
    $existing = @(
        do {
            $response = Invoke-AzRestMethod -Method GET -Path $nextPath -ErrorAction Stop
            if ($response.StatusCode -ne 200) {
                throw "Cannot list role assignments at '$($role.Scope)' ($($response.StatusCode)): $($response.Content)"
            }
            $page = $response.Content | ConvertFrom-Json
            if ($null -eq $page -or -not $page.PSObject.Properties['value']) {
                throw "Role assignment listing at '$($role.Scope)' is missing its value array."
            }
            $page.value | Where-Object {
                $_.properties.principalId -ieq $principalId -and
                $_.properties.roleDefinitionId -ieq $roleDefinitionId -and
                $_.properties.scope -ieq $role.Scope
            }
            $nextPath = if ($page.nextLink) { ([uri] $page.nextLink).PathAndQuery } else { $null }
        } while ($nextPath)
    )
    if ($existing.Count -eq 0) {
        $roleAssignmentName = [guid]::NewGuid().ToString()
        $payload = @{
            properties = @{
                principalId = $principalId
                principalType = 'ServicePrincipal'
                roleDefinitionId = $roleDefinitionId
            }
        } | ConvertTo-Json -Depth 5
        $response = Invoke-AzRestMethod -Method PUT `
            -Path "$roleAssignmentsPath/${roleAssignmentName}?api-version=2022-04-01" `
            -Payload $payload -ErrorAction Stop
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "Cannot grant role at '$($role.Scope)' ($($response.StatusCode)): $($response.Content)"
        }
    }
}

$accountsVersion = '5.3.3'
$runtimeName = 'KvCertRemediation-PowerShell74'
$automationPath = "$subscriptionScope/resourceGroups/$AutomationResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
$runtimePath = "$automationPath/runtimeEnvironments/$runtimeName"
$apiVersion = '2024-10-23'

function Invoke-AutomationRequest {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('GET', 'PUT')] [string] $Method = 'GET',
        [string] $Payload
    )

    $arguments = @{ Path = $Path; Method = $Method; ErrorAction = 'Stop' }
    if ($Method -eq 'PUT') { $arguments.Payload = $Payload }
    $response = Invoke-AzRestMethod @arguments
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Automation request failed ($($response.StatusCode)): $($response.Content)"
    }
    $response.Content | ConvertFrom-Json
}

$payload = @{
    location = $Location
    properties = @{
        description = 'PowerShell 7.4 environment dedicated to certificate policy remediation.'
        runtime = @{ language = 'PowerShell'; version = '7.4' }
    }
} | ConvertTo-Json -Depth 5
$runtime = Invoke-AutomationRequest -Path "${runtimePath}?api-version=$apiVersion" -Method PUT -Payload $payload
if ($runtime.properties.runtime.language -ne 'PowerShell' -or $runtime.properties.runtime.version -ne '7.4') {
    throw "Runtime environment '$runtimeName' was not configured as PowerShell 7.4."
}

$packagesPath = "$runtimePath/packages"
$nextPath = "${packagesPath}?api-version=$apiVersion"
$packages = @(
    do {
        $page = Invoke-AutomationRequest -Path $nextPath
        if ($null -eq $page -or -not $page.PSObject.Properties['value']) {
            throw 'Runtime package listing is missing its value array.'
        }
        $page.value | Where-Object { $_.name -eq 'Az.Accounts' }
        $nextPath = if ($page.nextLink) { ([uri] $page.nextLink).PathAndQuery } else { $null }
    } while ($nextPath)
)
$packagePath = "$packagesPath/Az.Accounts"
$package = $packages | Select-Object -First 1
if (-not $package -or -not $package.properties.version -or [version] $package.properties.version -lt [version] $accountsVersion -or $package.properties.provisioningState -ne 'Succeeded') {
    $payload = @{
        location = $Location
        properties = @{
            contentLink = @{ uri = "https://www.powershellgallery.com/api/v2/package/Az.Accounts/$accountsVersion" }
        }
    } | ConvertTo-Json -Depth 5
    Invoke-AutomationRequest -Path "${packagePath}?api-version=$apiVersion" -Method PUT -Payload $payload | Out-Null
}
$deadline = [DateTime]::UtcNow.AddMinutes(20)
do {
    $package = Invoke-AutomationRequest -Path "${packagePath}?api-version=$apiVersion"
    if (-not $package.properties.provisioningState) {
        throw 'Az.Accounts runtime package response is missing provisioningState.'
    }
    if ($package.properties.provisioningState -eq 'Succeeded') {
        if (-not $package.properties.version -or [version] $package.properties.version -lt [version] $accountsVersion) {
            throw "Az.Accounts runtime package must be version $accountsVersion or later."
        }
        break
    }
    if ($package.properties.provisioningState -in @('Failed', 'Canceled')) {
        throw "Az.Accounts runtime package import failed: $($package | ConvertTo-Json -Depth 10 -Compress)"
    }
    if ([DateTime]::UtcNow -ge $deadline) {
        throw "Timed out importing Az.Accounts. Inspect packages in runtime environment '$runtimeName', then rerun."
    }
    Start-Sleep -Seconds 15
} while ($true)

Import-AzAutomationRunbook @automation -Name $runbookName -Type PowerShell `
    -Path (Join-Path $PSScriptRoot 'Invoke-KvCertRemediation.ps1') -Force | Out-Null

# Bind the imported draft through the API that supports named runtime environments.
$payload = @{
    location = $Location
    properties = @{
        runbookType = 'PowerShell'
        runtimeEnvironment = $runtimeName
        logProgress = $true
        logVerbose = $false
    }
} | ConvertTo-Json -Depth 5
$boundRunbook = Invoke-AutomationRequest -Path "$automationPath/runbooks/${runbookName}?api-version=$apiVersion" -Method PUT -Payload $payload
if ($boundRunbook.properties.runtimeEnvironment -ne $runtimeName) {
    throw "Runbook was not bound to runtime environment '$runtimeName'; refusing to publish."
}
Publish-AzAutomationRunbook @automation -Name $runbookName -ErrorAction Stop | Out-Null

$schedule = Get-AzAutomationSchedule @automation | Where-Object { $_.Name -eq $scheduleName }
if ($schedule) {
    if ($schedule.Frequency -ne 'Hour' -or $schedule.Interval -ne 1 -or -not $schedule.IsEnabled -or $schedule.ExpiryTime -le [DateTimeOffset]::UtcNow) {
        throw "Existing schedule '$scheduleName' is not an enabled, unexpired hourly schedule. Correct it before rerunning."
    }
}
else {
    New-AzAutomationSchedule @automation -Name $scheduleName -HourInterval 1 `
        -StartTime ([DateTimeOffset]::UtcNow.AddMinutes(10)) -TimeZone 'UTC' | Out-Null
}

if (-not ($links | Where-Object { $_.ScheduleName -eq $scheduleName })) {
    Register-AzAutomationScheduledRunbook @automation -RunbookName $runbookName `
        -ScheduleName $scheduleName -Parameters $runbookParameters | Out-Null
}

Write-Output "Published '$runbookName' in PowerShell 7.4 runtime '$runtimeName' with an hourly UTC schedule in '$AutomationAccountName'."
Write-Output "Target: $scope; assignment: $PolicyAssignmentId"
Write-Output 'First scheduled run starts in about 10 minutes for a new schedule. Allow RBAC propagation; inspect Automation jobs and Azure Policy remediation deployments.'
