<#
.SYNOPSIS
    Remediates one certificate policy assignment in a resource group using managed identity.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [Parameter(Mandatory)] [ValidatePattern('^[^/]+$')] [string] $ResourceGroupName,
    [Parameter(Mandatory)]
    [ValidatePattern('(?i)^/subscriptions/[^/]+(/resourceGroups/[^/]+)?/providers/Microsoft.Authorization/policyAssignments/[^/]+$')]
    [string] $PolicyAssignmentId
)

$ErrorActionPreference = 'Stop'
$subscriptionScope = "/subscriptions/$SubscriptionId"
$scope = "$subscriptionScope/resourceGroups/$ResourceGroupName"
$assignmentScope = $PolicyAssignmentId -replace '(?i)/providers/Microsoft.Authorization/policyAssignments/[^/]+$', ''
if ($assignmentScope -ine $subscriptionScope -and $assignmentScope -ine $scope) {
    throw 'The assignment must be scoped to the target resource group or its subscription.'
}

Import-Module Az.Accounts -MinimumVersion 5.3.3 -ErrorAction Stop
Disable-AzContextAutosave -Scope Process | Out-Null
$context = (Connect-AzAccount -Identity -Subscription $SubscriptionId -ErrorAction Stop).Context
$context = Set-AzContext -SubscriptionId $SubscriptionId -DefaultProfile $context -ErrorAction Stop

function Invoke-RemediationRequest {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('GET', 'PUT')] [string] $Method = 'GET',
        [string] $Payload
    )

    $arguments = @{ Method = $Method; DefaultProfile = $context; ErrorAction = 'Stop' }
    if ($Path.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        $arguments.Uri = $Path
    }
    else {
        $arguments.Path = $Path
    }
    if ($Method -eq 'PUT') {
        $arguments.Payload = $Payload
    }
    $response = Invoke-AzRestMethod @arguments
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Remediation request failed ($($response.StatusCode)): $($response.Content)"
    }
    $response.Content | ConvertFrom-Json
}

$basePath = "$scope/providers/Microsoft.PolicyInsights/remediations"
$nextLink = "${basePath}?api-version=2021-10-01"
$remediations = @(
    do {
        $page = Invoke-RemediationRequest -Path $nextLink
        if ($null -eq $page -or -not $page.PSObject.Properties['value']) {
            throw 'Remediation listing response is missing its value array.'
        }
        $page.value | Where-Object { $_.properties.policyAssignmentId -ieq $PolicyAssignmentId }
        $nextLink = $page.nextLink
    } while ($nextLink)
)

$terminalStates = @('Succeeded', 'Failed', 'Canceled')
$active = @($remediations | Where-Object { $_.properties.provisioningState -notin $terminalStates })
if ($active.Count -gt 0) {
    Write-Output "Skipping: remediation already active for this assignment: $($active.name -join ', ')."
    return
}

$latest = $remediations | Sort-Object { $_.properties.createdOn } -Descending | Select-Object -First 1
if ($latest -and ($latest.properties.provisioningState -ne 'Succeeded' -or $latest.properties.deploymentStatus.failedDeployments -gt 0)) {
    Write-Warning "Previous remediation '$($latest.name)' ended in $($latest.properties.provisioningState); failed deployments: $($latest.properties.deploymentStatus.failedDeployments). Inspect Azure Policy remediation deployments."
}

$name = 'kv-cert-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$taskPath = "$basePath/${name}?api-version=2021-10-01"
$payload = @{
    properties = @{
        policyAssignmentId = $PolicyAssignmentId
        resourceDiscoveryMode = 'ReEvaluateCompliance'
    }
} | ConvertTo-Json -Depth 5

$task = Invoke-RemediationRequest -Path $taskPath -Method PUT -Payload $payload
Write-Output "Started remediation '$name' at '$scope' with ReEvaluateCompliance."

$timer = [Diagnostics.Stopwatch]::StartNew()
while ($true) {
    if (-not $task.properties.provisioningState) {
        throw "Remediation '$name' response is missing provisioningState. Inspect the Azure remediation before retrying."
    }
    if ($task.properties.provisioningState -in $terminalStates) { break }
    if ($timer.Elapsed.TotalMinutes -ge 45) {
        throw "Timed out waiting for '$name'. The Azure remediation is NOT canceled; inspect it before retrying. Future runs skip while it remains active."
    }
    Start-Sleep -Seconds 30
    $task = Invoke-RemediationRequest -Path $taskPath
}

if ($task.properties.provisioningState -ne 'Succeeded' -or $task.properties.deploymentStatus.failedDeployments -gt 0) {
    throw "Remediation '$name' ended in $($task.properties.provisioningState); failed deployments: $($task.properties.deploymentStatus.failedDeployments). Inspect Azure Policy remediation deployments."
}
Write-Output "Remediation '$name' succeeded. Deployments: $($task.properties.deploymentStatus.totalDeployments); failed: $($task.properties.deploymentStatus.failedDeployments)."
