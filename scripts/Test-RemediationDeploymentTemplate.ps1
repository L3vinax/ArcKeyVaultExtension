[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$template = Get-Content -Raw (Join-Path $root 'azuredeploy-remediation.json') | ConvertFrom-Json
$deployScript = Get-Content -Raw (Join-Path $PSScriptRoot 'Deploy-KvCertRemediationAutomation.ps1')
$readme = Get-Content -Raw (Join-Path $root 'README.md')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

Assert-True ($template.'$schema' -ceq 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#') 'Automation deployment must use subscription scope.'
$deployments = @($template.resources | Where-Object { $_.type -ceq 'Microsoft.Resources/deployments' })
$roles = @($template.resources | Where-Object { $_.type -ceq 'Microsoft.Authorization/roleAssignments' })
Assert-True ($template.resources.Count -eq 4 -and $deployments.Count -eq 2 -and $roles.Count -eq 2) 'Only Automation deployments and scoped role assignments may be created.'

$accountDeployment = $deployments | Where-Object { $_.name -ceq "[variables('automationDeploymentName')]" }
$scheduleDeployment = $deployments | Where-Object { $_.name -ceq "[variables('scheduleDeploymentName')]" }
Assert-True ($null -ne $accountDeployment -and $null -ne $scheduleDeployment) 'Account and scheduling deployments must be separate.'
foreach ($deployment in $deployments) {
    Assert-True ($deployment.resourceGroup -ceq "[parameters('automationResourceGroupName')]") 'Deploy only to the existing Automation resource group.'
    Assert-True ($deployment.properties.mode -ceq 'Incremental') 'Nested deployments must preserve unrelated resources.'
    Assert-True ($deployment.properties.expressionEvaluationOptions.scope -ceq 'inner') 'Nested parameters and resource IDs must evaluate in their own scope.'
    Assert-True ($deployment.properties.template.'$schema' -ceq 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#') 'Nested deployments must use resource-group scope.'
}

Assert-True ($template.variables.automationResourceGroupId -ceq "[subscriptionResourceId('Microsoft.Resources/resourceGroups', parameters('automationResourceGroupName'))]") 'Build the Automation resource-group ID at subscription scope.'
Assert-True ($template.variables.automationAccountId -ceq "[extensionResourceId(variables('automationResourceGroupId'), 'Microsoft.Automation/automationAccounts', parameters('automationAccountName'))]") 'Build the account ID under its resource group without subscription-scope resourceId overloads.'
Assert-True ($template.variables.automationDeploymentId -ceq "[extensionResourceId(variables('automationResourceGroupId'), 'Microsoft.Resources/deployments', variables('automationDeploymentName'))]") 'Build the nested deployment ID under its resource group.'

# resourceId uses subscription semantics outside the inner resource-group templates.
$outerTemplate = $template | ConvertTo-Json -Depth 100 | ConvertFrom-Json
foreach ($resource in $outerTemplate.resources | Where-Object { $_.type -ceq 'Microsoft.Resources/deployments' }) {
    $resource.properties.template = $null
}
$outerJson = $outerTemplate | ConvertTo-Json -Depth 100 -Compress
Assert-True ($outerJson -notmatch '(?i)(?<![a-z])resourceId\s*\(') 'Do not use resourceId in subscription-scope expressions; a resource-group name can be interpreted as a subscription ID.'

$accountResources = $accountDeployment.properties.template.resources
$account = $accountResources | Where-Object { $_.type -ceq 'Microsoft.Automation/automationAccounts' }
$runtime = $accountResources | Where-Object { $_.type -ceq 'Microsoft.Automation/automationAccounts/runtimeEnvironments' }
$package = $accountResources | Where-Object { $_.type -ceq 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages' }
$runbook = $accountResources | Where-Object { $_.type -ceq 'Microsoft.Automation/automationAccounts/runbooks' }
Assert-True ($accountResources.Count -eq 4 -and $null -ne $account -and $null -ne $runtime -and $null -ne $package -and $null -ne $runbook) 'Account deployment must contain only account, runtime, attached package, and runbook.'
Assert-True ($account.identity.type -ceq 'SystemAssigned' -and $account.properties.sku.name -ceq 'Basic') 'Automation must use a system-assigned identity and Basic SKU.'
Assert-True ($accountDeployment.properties.parameters.location.value -ceq "[parameters('automationLocation')]") 'Use the Automation location, not the subscription deployment location.'
Assert-True ($runtime.name -ceq "[concat(parameters('accountName'), '/KvCertRemediation-PowerShell74')]" -and $runtime.apiVersion -ceq '2024-10-23') 'Create the named runtime with a supported API.'
Assert-True ($runtime.properties.runtime.language -ceq 'PowerShell' -and $runtime.properties.runtime.version -ceq '7.4') 'Runtime must be PowerShell 7.4.'
Assert-True ($runtime.location -ceq "[parameters('location')]" -and $package.location -ceq "[parameters('location')]") 'Runtime and attached package need the account location.'
Assert-True ($runtime.dependsOn -contains "[resourceId('Microsoft.Automation/automationAccounts', parameters('accountName'))]") 'Runtime must depend on the account.'
Assert-True ($package.name -ceq "[concat(parameters('accountName'), '/KvCertRemediation-PowerShell74/Az.Accounts')]" -and $package.apiVersion -ceq '2024-10-23') 'Az.Accounts must be attached under the named runtime.'
Assert-True ($package.properties.contentLink.uri -ceq 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/5.3.3') 'Pin the tested Az.Accounts version.'
Assert-True ($deployScript.Contains("`$accountsVersion = '5.3.3'") -and $deployScript.Contains("`$runtimeName = 'KvCertRemediation-PowerShell74'")) 'Template and deployment script runtime/package settings must match.'
Assert-True ($package.dependsOn -contains "[resourceId('Microsoft.Automation/automationAccounts/runtimeEnvironments', parameters('accountName'), 'KvCertRemediation-PowerShell74')]") 'Attach the package after runtime creation.'
Assert-True ($runbook.properties.runbookType -ceq 'PowerShell' -and $runbook.properties.runtimeEnvironment -ceq 'KvCertRemediation-PowerShell74' -and $runbook.apiVersion -ceq '2024-10-23') 'Runbook must explicitly bind to the PowerShell 7.4 runtime.'
Assert-True ($runbook.name -ceq "[concat(parameters('accountName'), '/Invoke-KvCertRemediation')]") 'Publish the existing runbook name.'
Assert-True ($runbook.dependsOn -contains "[resourceId('Microsoft.Automation/automationAccounts/runtimeEnvironments/packages', parameters('accountName'), 'KvCertRemediation-PowerShell74', 'Az.Accounts')]") 'Publish after attached package deployment.'
$sourceUri = 'https://raw.githubusercontent.com/L3vinax/ArcKeyVaultExtension/main/scripts/Invoke-KvCertRemediation.ps1'
Assert-True ($template.parameters.runbookContentUri.defaultValue -ceq $sourceUri) 'Default source must be the existing runbook on main.'
Assert-True ($accountDeployment.properties.parameters.runbookContentUri.value -ceq "[parameters('runbookContentUri')]" -and $runbook.properties.publishContentLink.uri -ceq "[parameters('runbookContentUri')]") 'Pass source URL through to published content, not draft content.'
Assert-True (Test-Path (Join-Path $PSScriptRoot 'Invoke-KvCertRemediation.ps1')) 'The source runbook must exist locally.'

$assignmentInput = $template.parameters.policyAssignmentId
Assert-True ($assignmentInput.type -ceq 'string' -and $assignmentInput.minLength -eq 1) 'Require a non-empty full assignment resource ID.'
Assert-True (-not $assignmentInput.PSObject.Properties['maxLength']) 'Full assignment resource IDs must not have a 64-character limit.'
Assert-True (-not $assignmentInput.PSObject.Properties['allowedValues'] -and -not $assignmentInput.PSObject.Properties['defaultValue']) 'Assignment ID must be a required free-text resource ID, not a scope selector.'
Assert-True (-not $template.parameters.PSObject.Properties['policyAssignmentName']) 'Remove the separate assignment-name parameter.'
Assert-True (-not $template.parameters.PSObject.Properties['policyAssignmentScope']) 'Remove the separate scope selector.'
Assert-True ($template.variables.policyAssignmentId -ceq "[parameters('policyAssignmentId')]") 'Pass the full assignment resource ID through unchanged to scoped RBAC, schedule parameters, and outputs.'
Assert-True ($template.outputs.policyAssignmentId.value -ceq "[variables('policyAssignmentId')]") 'Output the full supplied assignment ID.'
Assert-True ($template.variables.targetScope -ceq "[subscriptionResourceId('Microsoft.Resources/resourceGroups', parameters('targetResourceGroupName'))]") 'Target role must be scoped to the selected resource group.'
Assert-True ($template.variables.policyContributorRoleId -ceq "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '36243c78-bf99-498c-9df9-86d9f8d28608')]") 'Grant Resource Policy Contributor, matching the script.'
Assert-True ($template.variables.readerRoleId -ceq "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')]") 'Grant Reader, matching the script.'
$accountDeploymentId = "[variables('automationDeploymentId')]"
$principalExpression = "[reference(variables('automationDeploymentId'), '2022-09-01').outputs.principalId.value]"
$expectedRoles = @(
    @{ Scope = 'targetScope'; Role = 'policyContributorRoleId' },
    @{ Scope = 'policyAssignmentId'; Role = 'readerRoleId' }
)
foreach ($expected in $expectedRoles) {
    $role = @($roles | Where-Object { $_.scope -ceq "[variables('$($expected.Scope)')]" })
    Assert-True ($role.Count -eq 1) "Missing or duplicate role at $($expected.Scope)."
    Assert-True ($role[0].properties.roleDefinitionId -ceq "[variables('$($expected.Role)')]") 'Role must match its intended scope.'
    Assert-True ($role[0].properties.principalType -ceq 'ServicePrincipal' -and $role[0].properties.principalId -ceq $principalExpression) 'Roles must target the new Automation identity.'
    Assert-True ($role[0].dependsOn -contains $accountDeploymentId) 'Roles must wait for the resource-group account deployment.'
    $expectedName = "[guid(variables('$($expected.Scope)'), variables('automationAccountId'), variables('$($expected.Role)'))]"
    Assert-True ($role[0].name -ceq $expectedName) 'Role names must be deterministic.'
    $roleId = "[extensionResourceId(variables('$($expected.Scope)'), 'Microsoft.Authorization/roleAssignments', guid(variables('$($expected.Scope)'), variables('automationAccountId'), variables('$($expected.Role)')))]"
    Assert-True ($scheduleDeployment.dependsOn -contains $roleId) 'Scheduling must wait for each scoped role assignment.'
}
Assert-True ($scheduleDeployment.dependsOn.Count -eq 3 -and $scheduleDeployment.dependsOn -contains $accountDeploymentId) 'Scheduling must wait for the runbook and both grants.'

$scheduleTemplate = $scheduleDeployment.properties.template
$schedule = $scheduleTemplate.resources | Where-Object { $_.type -ceq 'Microsoft.Automation/automationAccounts/schedules' }
$link = $scheduleTemplate.resources | Where-Object { $_.type -ceq 'Microsoft.Automation/automationAccounts/jobSchedules' }
Assert-True ($scheduleTemplate.resources.Count -eq 2 -and $null -ne $schedule -and $null -ne $link) 'Scheduling must create exactly one schedule and one link.'
Assert-True ($schedule.properties.frequency -ceq 'Hour' -and $schedule.properties.interval -eq 1 -and $schedule.properties.timeZone -ceq 'UTC') 'Schedule must be hourly in UTC.'
Assert-True ($scheduleTemplate.parameters.scheduleStartTime.defaultValue -ceq "[dateTimeAdd(utcNow(), 'PT10M')]" -and $schedule.properties.startTime -ceq "[parameters('scheduleStartTime')]") 'Generate start time after account and role provisioning.'
Assert-True ($link.properties.runbook.name -ceq 'Invoke-KvCertRemediation' -and $link.properties.schedule.name -ceq 'KvCertRemediation-Hourly') 'Link the correct runbook and schedule.'
Assert-True ($link.name -ceq "[concat(parameters('accountName'), '/', guid(resourceId('Microsoft.Automation/automationAccounts', parameters('accountName')), 'Invoke-KvCertRemediation', 'KvCertRemediation-Hourly'))]") 'Use one deterministic schedule link per dedicated account.'
Assert-True ($link.dependsOn -contains "[resourceId('Microsoft.Automation/automationAccounts/schedules', parameters('accountName'), 'KvCertRemediation-Hourly')]") 'Schedule link must wait for schedule creation.'
$expectedParameters = @{
    SubscriptionId = @{ Inner = 'subscriptionId'; Outer = '[subscription().subscriptionId]' }
    ResourceGroupName = @{ Inner = 'targetResourceGroupName'; Outer = "[parameters('targetResourceGroupName')]" }
    PolicyAssignmentId = @{ Inner = 'policyAssignmentId'; Outer = "[variables('policyAssignmentId')]" }
}
Assert-True ($link.properties.parameters.PSObject.Properties.Name.Count -eq 3) 'Pass exactly the three required runbook parameters.'
foreach ($name in $expectedParameters.Keys) {
    $expected = $expectedParameters[$name]
    Assert-True ($link.properties.parameters.$name -ceq "[parameters('$($expected.Inner)')]") "Incorrect runbook parameter: $name."
    Assert-True ($scheduleDeployment.properties.parameters.($expected.Inner).value -ceq $expected.Outer) "Incorrect outer parameter: $name."
}

$templateUri = [Uri]::EscapeDataString('https://raw.githubusercontent.com/L3vinax/ArcKeyVaultExtension/main/azuredeploy-remediation.json')
Assert-True ($readme.Contains("https://portal.azure.com/#create/Microsoft.Template/uri/$templateUri")) 'README button must reference the Automation template on main.'
Write-Output 'PASS: Automation-only deployment, subscription-safe resource IDs, scoped identity permissions, PowerShell 7.4 runtime and attached Az.Accounts package, explicit runbook binding, hourly schedule ordering and parameters, stable resource names, and portal button URL.'
