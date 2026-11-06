[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:deploymentMode = $false
$subscription = '11111111-1111-1111-1111-111111111111'
$scope = "/subscriptions/$subscription/resourceGroups/servers"
$assignmentId = "/subscriptions/$subscription/providers/Microsoft.Authorization/policyAssignments/cert-policy"
$runbookPath = Join-Path $PSScriptRoot 'Invoke-KvCertRemediation.ps1'
$deployPath = Join-Path $PSScriptRoot 'Deploy-KvCertRemediationAutomation.ps1'
$runbook = [scriptblock]::Create((Get-Content -LiteralPath $runbookPath -Raw))

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Test-Case {
    param([string] $Name, [scriptblock] $Body)
    & $Body
    $script:passed++
    Write-Output "PASS: $Name"
}

function Assert-Throws {
    param([scriptblock] $Body, [string] $Pattern)
    $caught = $null
    try { & $Body | Out-Null }
    catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected a terminating error.'
    Assert-True ($caught.Exception.Message -match $Pattern) "Unexpected error: $caught"
}

# All Azure calls are replaced; these tests require neither modules nor an Azure login.
function Import-Module { [CmdletBinding()] param($Name, $MinimumVersion) }
function Disable-AzContextAutosave { param($Scope) }
function Connect-AzAccount {
    [CmdletBinding()] param([switch] $Identity, $Subscription)
    Assert-True $Identity.IsPresent 'Runbook must use managed identity.'
    [pscustomobject] @{ Context = 'test-context' }
}
function Set-AzContext { [CmdletBinding()] param($SubscriptionId, $DefaultProfile) 'test-context' }
function Start-Sleep { param($Seconds) }

function New-Task {
    param([string] $State, [int] $Failed = 0, [string] $Assignment = $assignmentId)
    @{
        name = 'existing-task'
        properties = @{
            policyAssignmentId = $Assignment
            provisioningState = $State
            createdOn = '2026-10-23T00:00:00Z'
            deploymentStatus = @{ totalDeployments = 1; failedDeployments = $Failed }
        }
    }
}

function Set-Responses {
    param([object[]] $Responses)
    $script:responses = [Collections.Generic.Queue[object]]::new()
    foreach ($response in $Responses) {
        $script:responses.Enqueue([pscustomobject] @{
            StatusCode = 200
            Content = ($response | ConvertTo-Json -Depth 20 -Compress)
        })
    }
    $script:requests = [Collections.Generic.List[object]]::new()
}

function Invoke-AzRestMethod {
    [CmdletBinding()] param($Path, $Uri, $Method, $Payload, $DefaultProfile)
    $script:requests.Add(@{ Path = $Path; Uri = $Uri; Method = $Method; Payload = $Payload })
    if ($script:deploymentMode -and $Path -match '/providers/Microsoft.Automation/') {
        Assert-True ($Path -match 'api-version=2024-10-23') 'Use the API supporting runtime environments.'
        if ($script:automationStatus -ne 200) {
            return [pscustomobject] @{ StatusCode = $script:automationStatus; Content = 'Automation request denied' }
        }
        $result = @{}
        if ($Path -match '/runtimeEnvironments/KvCertRemediation-PowerShell74\?') {
            Assert-True ($Method -eq 'PUT') 'Create or update the named runtime.'
            $body = $Payload | ConvertFrom-Json
            Assert-True ($body.properties.runtime.language -ceq 'PowerShell' -and $body.properties.runtime.version -ceq '7.4') 'Runtime must be PowerShell 7.4.'
            Assert-True ($body.location -ceq 'eastus') 'Runtime needs the account location.'
            $script:runtimeCreated = $true
            $result = $body
        }
        elseif ($Path -match '/runtimeEnvironments/KvCertRemediation-PowerShell74/packages\?') {
            Assert-True ($Method -eq 'GET' -and $script:runtimeCreated) 'List packages attached to the named runtime.'
            if (-not $script:malformedPackageListing) {
                $result = @{ value = @($script:package | Where-Object { $null -ne $_ }) }
            }
        }
        elseif ($Path -match '/runtimeEnvironments/KvCertRemediation-PowerShell74/packages/Az.Accounts\?') {
            Assert-True $script:runtimeCreated 'Package must belong to the created runtime.'
            if ($Method -eq 'PUT') {
                $body = $Payload | ConvertFrom-Json
                Assert-True ($body.location -ceq 'eastus') 'Package needs the account location.'
                Assert-True ($body.properties.contentLink.uri -ceq 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/5.3.3') 'Attach the pinned Az.Accounts package.'
                $script:importedPackages++
                $script:package = @{
                    name = 'Az.Accounts'
                    properties = @{ version = $script:packageVersion; provisioningState = $script:packageState }
                }
            }
            else {
                Assert-True ($Method -eq 'GET') 'Poll the attached package.'
                if ($script:packagePollStates.Count -gt 0) {
                    $script:package.properties.provisioningState = $script:packagePollStates[0]
                    $script:packagePollStates = @($script:packagePollStates | Select-Object -Skip 1)
                }
            }
            $result = $script:package
        }
        elseif ($Path -match '/runbooks/Invoke-KvCertRemediation\?') {
            Assert-True ($Method -eq 'PUT' -and $script:importedDrafts -gt 0) 'Bind the imported draft before publishing.'
            $body = $Payload | ConvertFrom-Json
            Assert-True ($body.properties.runbookType -ceq 'PowerShell' -and $body.properties.runtimeEnvironment -ceq 'KvCertRemediation-PowerShell74') 'Bind runbook to the PowerShell 7.4 runtime.'
            $script:boundRuntime = if ($script:wrongRuntimeBinding) { 'wrong-runtime' } else { $body.properties.runtimeEnvironment }
            $result = @{ properties = @{ runtimeEnvironment = $script:boundRuntime } }
        }
        else { throw "Unexpected Automation request: $Path" }
        return [pscustomobject] @{ StatusCode = 200; Content = ($result | ConvertTo-Json -Depth 10) }
    }
    if ($script:deploymentMode -and $Path -match '(?i)/providers/Microsoft.Authorization/roleAssignments[/?]') {
        Assert-True ($Path -match 'api-version=2022-04-01') 'Use the stable RBAC API.'
        if ($Method -eq 'GET') {
            $roleScope = ($Path -split '(?i)/providers/Microsoft.Authorization/roleAssignments')[0]
            $values = @($script:roleAssignments | Where-Object { $_.Scope -ieq $roleScope } | ForEach-Object {
                @{ properties = @{
                    scope = $_.Scope
                    principalId = $(if ($_.PrincipalId) { $_.PrincipalId } else { 'test-principal' })
                    roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/$($_.RoleDefinitionId)"
                } }
            })
            return [pscustomobject] @{ StatusCode = 200; Content = (@{ value = $values } | ConvertTo-Json -Depth 10) }
        }
        Assert-True ($Method -eq 'PUT') 'Unexpected RBAC method.'
        if ($script:roleWriteStatus -ne 201) {
            return [pscustomobject] @{ StatusCode = $script:roleWriteStatus; Content = 'Role assignment denied' }
        }
        $body = $Payload | ConvertFrom-Json
        Assert-True ($body.properties.principalType -eq 'ServicePrincipal') 'Avoid new-principal directory lookup.'
        Assert-True ($body.properties.principalId -eq 'test-principal') 'Grant must target the Automation identity.'
        $script:roleAssignments += [pscustomobject] @{
            Scope = ($Path -split '(?i)/providers/Microsoft.Authorization/roleAssignments')[0]
            RoleDefinitionId = ($body.properties.roleDefinitionId -split '/')[-1]
            PrincipalId = $body.properties.principalId
        }
        return [pscustomobject] @{ StatusCode = 201; Content = '{}' }
    }
    if ($script:responses.Count -eq 0) { throw 'Unexpected REST request.' }
    $script:responses.Dequeue()
}

$runbookParameters = @{
    SubscriptionId = $subscription
    ResourceGroupName = 'servers'
    PolicyAssignmentId = $assignmentId
}

Test-Case 'Fresh discovery, correct scope and assignment, and completion polling' {
    Set-Responses @(@{ value = @() }, (New-Task Running), (New-Task Succeeded))
    $output = & $runbook @runbookParameters
    Assert-True ($script:requests.Count -eq 3) 'Expected list, create, and poll.'
    $create = $script:requests[1]
    $body = $create.Payload | ConvertFrom-Json
    Assert-True ($create.Method -eq 'PUT') 'Must create remediation.'
    Assert-True ($create.Path.StartsWith("$scope/providers/Microsoft.PolicyInsights/remediations/kv-cert-")) 'Wrong remediation scope/name.'
    Assert-True ($body.properties.policyAssignmentId -eq $assignmentId) 'Wrong assignment.'
    Assert-True ($body.properties.resourceDiscoveryMode -eq 'ReEvaluateCompliance') 'Must discover fresh compliance.'
    Assert-True (($output -join ' ') -match 'succeeded') 'Missing completion output.'
}

foreach ($state in @('Accepted', 'Running', 'Evaluating', 'Cancelling', 'UnknownFutureState')) {
    Test-Case "Skipping active task in state $state" {
        Set-Responses @(@{ value = @((New-Task $state)) })
        $output = & $runbook @runbookParameters
        Assert-True ($script:requests.Count -eq 1) 'Must not create overlapping remediation.'
        Assert-True (($output -join ' ') -match 'Skipping') 'Skip must be visible.'
    }
}

Test-Case 'Pagination finds active tasks beyond the first page' {
    Set-Responses @(
        @{ value = @((New-Task Running 0 '/other-assignment')); nextLink = 'https://management.azure.com/next-page' },
        @{ value = @((New-Task Running)) }
    )
    & $runbook @runbookParameters | Out-Null
    Assert-True ($script:requests.Count -eq 2) 'Expected two list pages only.'
    Assert-True ($script:requests[1].Uri -eq 'https://management.azure.com/next-page') 'Must follow nextLink.'
}

foreach ($state in @('Failed', 'Canceled')) {
    Test-Case "Failing job for terminal remediation state $state" {
        Set-Responses @(@{ value = @() }, (New-Task $state))
        Assert-Throws { & $runbook @runbookParameters } "ended in $state"
    }
}

Test-Case 'Partial deployment failure fails the job even if task state is Succeeded' {
    Set-Responses @(@{ value = @() }, (New-Task Succeeded 1))
    Assert-Throws { & $runbook @runbookParameters } 'failed deployments: 1'
}

Test-Case 'Previous failure is warned about and retried' {
    Set-Responses @(@{ value = @((New-Task Failed 1)) }, (New-Task Succeeded))
    $warnings = @()
    & $runbook @runbookParameters -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
    Assert-True ($warnings.Count -eq 1) 'Previous failure must be surfaced.'
    Assert-True ($script:requests[1].Method -eq 'PUT') 'Terminal failure must permit retry.'
}

Test-Case 'Resource-group assignment is supported' {
    $parameters = $runbookParameters.Clone()
    $parameters.PolicyAssignmentId = "$scope/providers/Microsoft.Authorization/policyAssignments/rg-policy"
    Set-Responses @(@{ value = @() }, (New-Task Succeeded))
    & $runbook @parameters | Out-Null
    $body = $script:requests[1].Payload | ConvertFrom-Json
    Assert-True ($body.properties.policyAssignmentId -eq $parameters.PolicyAssignmentId) 'RG assignment was changed.'
}

Test-Case 'Assignment outside the target scope is rejected before any Azure call' {
    $parameters = $runbookParameters.Clone()
    $parameters.PolicyAssignmentId = "/subscriptions/$subscription/resourceGroups/other/providers/Microsoft.Authorization/policyAssignments/other"
    Set-Responses @()
    Assert-Throws { & $runbook @parameters } 'assignment must be scoped'
    Assert-True ($script:requests.Count -eq 0) 'Invalid scope must not call Azure.'
}

Test-Case 'REST errors fail explicitly' {
    Set-Responses @()
    $script:responses.Enqueue([pscustomobject] @{ StatusCode = 403; Content = 'Access denied' })
    Assert-Throws { & $runbook @runbookParameters } '403.*Access denied'
}

Test-Case 'Malformed REST response is not treated as success' {
    Set-Responses @()
    $script:responses.Enqueue([pscustomobject] @{ StatusCode = 200; Content = 'not-json' })
    Assert-Throws { & $runbook @runbookParameters } 'JSON'
}

Test-Case 'Incomplete list response cannot bypass the overlap check' {
    Set-Responses @(@{})
    Assert-Throws { & $runbook @runbookParameters } 'missing its value array'
}

Test-Case 'Incomplete task response fails explicitly' {
    Set-Responses @(@{ value = @() }, @{ properties = @{} })
    Assert-Throws { & $runbook @runbookParameters } 'missing provisioningState'
}

function Reset-Deployment {
    $script:account = $null
    $script:links = @()
    $script:roleAssignments = @()
    $script:package = $null
    $script:packageState = 'Succeeded'
    $script:packageVersion = '5.3.3'
    $script:packagePollStates = @()
    $script:runtimeCreated = $false
    $script:boundRuntime = $null
    $script:importedDrafts = 0
    $script:automationStatus = 200
    $script:malformedPackageListing = $false
    $script:wrongRuntimeBinding = $false
    $script:schedule = $null
    $script:createdAccounts = 0
    $script:importedPackages = 0
    $script:publishedRunbooks = 0
    $script:createdSchedules = 0
    $script:roleWriteStatus = 201
    $script:assignment = @{
        identity = @{ type = 'SystemAssigned' }
        properties = @{
            policyDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/policyDefinitions/certs"
            parameters = @{ effect = @{ value = 'DeployIfNotExists' } }
        }
    }
}

function Get-AzResourceGroup { [CmdletBinding()] param($Name) }
function Get-AzAutomationAccount { param($ResourceGroupName) $script:account }
function New-AzAutomationAccount {
    param($ResourceGroupName, $Name, $Location, $Plan, [switch] $AssignSystemIdentity)
    Assert-True $AssignSystemIdentity.IsPresent 'Account needs managed identity.'
    $script:createdAccounts++
    $script:account = [pscustomobject] @{ AutomationAccountName = $Name; Identity = @{ PrincipalId = 'test-principal' } }
    $script:account
}
function Get-AzAutomationScheduledRunbook { param($ResourceGroupName, $AutomationAccountName, $RunbookName) $script:links }
function Get-AzRoleAssignment { throw 'Use REST for RBAC scopes containing subscription-level policy assignments.' }
function New-AzRoleAssignment { throw 'Use REST for RBAC scopes containing subscription-level policy assignments.' }
function Get-AzAutomationModule { throw 'Use packages attached to the PowerShell 7.4 runtime, not account modules.' }
function New-AzAutomationModule { throw 'Use packages attached to the PowerShell 7.4 runtime, not account modules.' }
function Import-AzAutomationRunbook {
    param($ResourceGroupName, $AutomationAccountName, $Name, $Type, $Path, [switch] $Published, [switch] $Force)
    Assert-True (-not $Published -and $Force -and $Type -eq 'PowerShell') 'Import a draft; bind runtime before publishing.'
    Assert-True (Test-Path -LiteralPath $Path) 'Runbook path does not exist.'
    Assert-True ($script:package.properties.provisioningState -eq 'Succeeded') 'Package must be ready before importing the runbook.'
    $script:importedDrafts++
}
function Publish-AzAutomationRunbook {
    [CmdletBinding()] param($ResourceGroupName, $AutomationAccountName, $Name)
    Assert-True ($script:boundRuntime -ceq 'KvCertRemediation-PowerShell74') 'Must bind PowerShell 7.4 before publishing.'
    $script:publishedRunbooks++
}
function Get-AzAutomationSchedule { param($ResourceGroupName, $AutomationAccountName) $script:schedule }
function New-AzAutomationSchedule {
    param($ResourceGroupName, $AutomationAccountName, $Name, $HourInterval, $StartTime, $TimeZone)
    Assert-True ($HourInterval -eq 1 -and $TimeZone -eq 'UTC') 'Schedule must run hourly in UTC.'
    Assert-True ($StartTime -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) 'Schedule starts too soon.'
    $script:createdSchedules++
    $script:schedule = [pscustomobject] @{
        Name = $Name; Frequency = 'Hour'; Interval = 1; IsEnabled = $true
        ExpiryTime = [DateTimeOffset]::MaxValue
    }
}
function Register-AzAutomationScheduledRunbook {
    param($ResourceGroupName, $AutomationAccountName, $RunbookName, $ScheduleName, $Parameters)
    $script:links += [pscustomobject] @{ RunbookName = $RunbookName; ScheduleName = $ScheduleName; Parameters = $Parameters }
}

# Execute the deployment body with local mocks instead of requiring installed Az modules.
$deploymentText = (Get-Content -LiteralPath $deployPath -Raw) -replace '(?m)^#Requires.*\r?\n', ''
$deploymentText = $deploymentText.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")
$deployment = [scriptblock]::Create($deploymentText)
$deploymentParameters = @{
    SubscriptionId = $subscription
    AutomationResourceGroupName = 'automation'
    AutomationAccountName = 'cert-remediation'
    Location = 'eastus'
    TargetResourceGroupName = 'servers'
    PolicyAssignmentId = $assignmentId
}

function Invoke-TestDeployment {
    Set-Responses @($script:assignment)
    $script:deploymentMode = $true
    try { & $deployment @deploymentParameters }
    finally { $script:deploymentMode = $false }
}

Test-Case 'Deploying account, scoped RBAC, PowerShell 7.4 runtime/package, published runbook, and hourly binding' {
    Reset-Deployment
    Invoke-TestDeployment | Out-Null
    Assert-True ($script:createdAccounts -eq 1) 'Expected one account.'
    Assert-True ($script:roleAssignments.Count -eq 2) 'Expected two role grants.'
    Assert-True ($script:roleAssignments[0].Scope -eq $scope) 'Remediation role must be RG-scoped.'
    Assert-True ($script:roleAssignments[1].Scope -eq $assignmentId) 'Reader must be assignment-scoped.'
    Assert-True ($script:runtimeCreated -and $script:importedPackages -eq 1 -and $script:publishedRunbooks -eq 1) 'Expected runtime, attached package, and runbook.'
    Assert-True ($script:createdSchedules -eq 1 -and $script:links.Count -eq 1) 'Expected one schedule and binding.'
    Assert-True ($script:links[0].Parameters.PolicyAssignmentId -eq $assignmentId) 'Binding must retain full assignment ID.'
}

Test-Case 'Redeployment does not duplicate accounts, RBAC, attached packages, or schedule links' {
    Invoke-TestDeployment | Out-Null
    Assert-True ($script:createdAccounts -eq 1 -and $script:roleAssignments.Count -eq 2) 'Account or RBAC duplicated.'
    Assert-True ($script:importedPackages -eq 1 -and $script:publishedRunbooks -eq 2) 'Only runbook should be republished.'
    Assert-True ($script:createdSchedules -eq 1 -and $script:links.Count -eq 1) 'Schedule or binding duplicated.'
}

Test-Case 'Schedule parameter matching handles case-sensitive dictionaries with lowercase keys' {
    $parameters = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($key in $script:links[0].Parameters.Keys) {
        $parameters.Add($key.ToLowerInvariant(), $script:links[0].Parameters[$key])
    }
    $script:links[0].Parameters = $parameters
    Invoke-TestDeployment | Out-Null
    Assert-True ($script:links.Count -eq 1) 'Must reuse the same binding.'
}

Test-Case 'Conflicting scheduled target is rejected' {
    $script:links[0].Parameters = @{ SubscriptionId = $subscription; ResourceGroupName = 'other'; PolicyAssignmentId = $assignmentId }
    Assert-Throws { Invoke-TestDeployment } 'different parameters'
}

Test-Case 'Disabled existing schedule is rejected' {
    Reset-Deployment
    Invoke-TestDeployment | Out-Null
    $script:schedule.IsEnabled = $false
    Assert-Throws { Invoke-TestDeployment } 'not an enabled'
}

Test-Case 'Initiative assignment is rejected' {
    Reset-Deployment
    $script:assignment.properties.policyDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/initiative'
    Assert-Throws { Invoke-TestDeployment } 'not an initiative'
}

Test-Case 'Audit-only assignment is rejected' {
    Reset-Deployment
    $script:assignment.properties.parameters.effect.value = 'AuditIfNotExists'
    Assert-Throws { Invoke-TestDeployment } 'effect must be DeployIfNotExists'
}

Test-Case 'Assignment without managed identity is rejected' {
    Reset-Deployment
    $script:assignment.identity.type = 'None'
    Assert-Throws { Invoke-TestDeployment } 'requires a managed identity'
}

Test-Case 'Existing account without system identity is rejected' {
    Reset-Deployment
    $script:account = [pscustomobject] @{ AutomationAccountName = 'cert-remediation'; Identity = $null }
    Assert-Throws { Invoke-TestDeployment } 'must have a system-assigned'
}

Test-Case 'Lowercase subscription-level policy assignment ID works without broadening Reader scope' {
    Reset-Deployment
    $deploymentParameters = $deploymentParameters.Clone()
    $deploymentParameters.PolicyAssignmentId = $assignmentId.ToLowerInvariant()
    Invoke-TestDeployment | Out-Null
    Assert-True ($script:roleAssignments[1].Scope -ceq $deploymentParameters.PolicyAssignmentId) 'Reader must remain on the exact assignment.'
    Assert-True ($script:links[0].Parameters.PolicyAssignmentId -ceq $deploymentParameters.PolicyAssignmentId) 'Retain the supplied ID.'
}

Test-Case 'Resource-group policy assignment receives assignment-scoped Reader access' {
    Reset-Deployment
    $deploymentParameters = $deploymentParameters.Clone()
    $deploymentParameters.PolicyAssignmentId = "$scope/providers/Microsoft.Authorization/policyAssignments/rg-policy"
    Invoke-TestDeployment | Out-Null
    Assert-True ($script:roleAssignments[1].Scope -eq $deploymentParameters.PolicyAssignmentId) 'Reader must remain assignment-scoped.'
}

Test-Case 'RBAC write error fails deployment explicitly before publishing or scheduling' {
    Reset-Deployment
    $script:roleWriteStatus = 403
    Assert-Throws { Invoke-TestDeployment } 'Cannot grant role.*403.*Role assignment denied'
    Assert-True ($script:publishedRunbooks -eq 0 -and $script:createdSchedules -eq 0) 'Do not publish or schedule after a failed grant.'
}

Test-Case 'Recovery reuses current Contributor and replaces only a missing Reader grant for a recreated identity' {
    Reset-Deployment
    $script:roleAssignments = @(
        [pscustomobject] @{ Scope = $scope; RoleDefinitionId = '36243c78-bf99-498c-9df9-86d9f8d28608'; PrincipalId = 'test-principal' },
        [pscustomobject] @{ Scope = $deploymentParameters.PolicyAssignmentId; RoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'; PrincipalId = 'deleted-account-principal' }
    )
    Invoke-TestDeployment | Out-Null
    $writes = @($script:requests | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/providers/Microsoft.Authorization/roleAssignments/' })
    Assert-True ($writes.Count -eq 1 -and $writes[0].Path.StartsWith("$($deploymentParameters.PolicyAssignmentId)/providers/Microsoft.Authorization/roleAssignments/")) 'Create only the missing Reader grant at the assignment resource.'
    Assert-True ($script:roleAssignments.Count -eq 3 -and $script:roleAssignments[1].PrincipalId -ceq 'deleted-account-principal') 'Keep existing grants untouched; do not mutate a stale identity grant.'
    Assert-True ($script:publishedRunbooks -eq 1 -and $script:links.Count -eq 1) 'Finish publishing and scheduling after reconciling grants.'
    Invoke-TestDeployment | Out-Null
    $writes = @($script:requests | Where-Object { $_.Method -eq 'PUT' -and $_.Path -match '/providers/Microsoft.Authorization/roleAssignments/' })
    Assert-True ($writes.Count -eq 0 -and $script:roleAssignments.Count -eq 3) 'A second recovery run must reuse both current-identity grants.'
}

Test-Case 'Package import is polled until the attached package succeeds' {
    Reset-Deployment
    $script:packagePollStates = @('Creating', 'Succeeded')
    Invoke-TestDeployment | Out-Null
    $polls = @($script:requests | Where-Object { $_.Method -eq 'GET' -and $_.Path -match '/packages/Az.Accounts\?' })
    Assert-True ($polls.Count -eq 2 -and $script:publishedRunbooks -eq 1) 'Wait for package success before publishing.'
}

foreach ($state in @('Failed', 'Canceled')) {
    Test-Case "Attached package import in state $state fails before publishing or scheduling" {
        Reset-Deployment
        $script:packageState = $state
        Assert-Throws { Invoke-TestDeployment } 'runtime package import failed'
        Assert-True ($script:importedDrafts -eq 0 -and $script:publishedRunbooks -eq 0 -and $script:createdSchedules -eq 0) 'Do not import, publish or schedule after package failure.'
    }
}

Test-Case 'Missing package provisioning state fails explicitly' {
    Reset-Deployment
    $script:packageState = $null
    Assert-Throws { Invoke-TestDeployment } 'missing provisioningState'
    Assert-True ($script:publishedRunbooks -eq 0) 'Do not publish with unknown package state.'
}

Test-Case 'Succeeded import with an older package version fails explicitly' {
    Reset-Deployment
    $script:packageVersion = '2.0.0'
    Assert-Throws { Invoke-TestDeployment } 'runtime package must be version 5.3.3 or later'
    Assert-True ($script:publishedRunbooks -eq 0) 'Do not publish with an unsupported package version.'
}

Test-Case 'Malformed package list is not treated as an empty list' {
    Reset-Deployment
    $script:malformedPackageListing = $true
    Assert-Throws { Invoke-TestDeployment } 'package listing is missing its value array'
    Assert-True ($script:importedPackages -eq 0 -and $script:publishedRunbooks -eq 0) 'Do not import or publish after an invalid list response.'
}

Test-Case 'Automation REST denial fails before publishing or scheduling' {
    Reset-Deployment
    $script:automationStatus = 403
    Assert-Throws { Invoke-TestDeployment } 'Automation request failed.*403.*Automation request denied'
    Assert-True ($script:publishedRunbooks -eq 0 -and $script:createdSchedules -eq 0) 'Do not publish or schedule after a failed runtime request.'
}

Test-Case 'Incorrect returned runtime binding prevents publication' {
    Reset-Deployment
    $script:wrongRuntimeBinding = $true
    Assert-Throws { Invoke-TestDeployment } 'not bound to runtime environment.*refusing to publish'
    Assert-True ($script:importedDrafts -eq 1 -and $script:publishedRunbooks -eq 0 -and $script:createdSchedules -eq 0) 'Keep the imported draft unpublished when runtime binding fails.'
}

Write-Output "PASS: $script:passed automation regression cases. No Azure resources were accessed."
