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
Assert-True ($template.resources.Count -eq 4 -and $deployments.Count -eq 3 -and $roles.Count -eq 1) 'Only account, target-group permissions, scheduling deployments, and a conditional subscription-assignment Reader grant may be created.'

$accountDeployment = $deployments | Where-Object { $_.name -ceq "[variables('automationDeploymentName')]" }
$scheduleDeployment = $deployments | Where-Object { $_.name -ceq "[variables('scheduleDeploymentName')]" }
$permissionsDeployment = $deployments | Where-Object { $_.name -ceq "[variables('permissionsDeploymentName')]" }
Assert-True ($null -ne $accountDeployment -and $null -ne $scheduleDeployment -and $null -ne $permissionsDeployment) 'Account, permissions, and scheduling deployments must be separate.'
foreach ($deployment in $deployments) {
    Assert-True ($deployment.properties.mode -ceq 'Incremental') 'Nested deployments must preserve unrelated resources.'
    Assert-True ($deployment.properties.expressionEvaluationOptions.scope -ceq 'inner') 'Nested parameters and resource IDs must evaluate in their own scope.'
    Assert-True ($deployment.properties.template.'$schema' -ceq 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#') 'Nested deployments must use resource-group scope.'
}
foreach ($deployment in @($accountDeployment, $scheduleDeployment)) {
    Assert-True ($deployment.resourceGroup -ceq "[parameters('automationResourceGroupName')]") 'Account and scheduling must deploy to the existing Automation resource group.'
}
Assert-True ($permissionsDeployment.resourceGroup -ceq "[parameters('targetResourceGroupName')]") 'Deploy the remediation permissions in the existing target resource group.'

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
Assert-True (-not $template.parameters.PSObject.Properties['automationLocation']) 'Use the portal Region selector instead of a separate Automation location field.'
Assert-True ($accountDeployment.properties.parameters.location.value -ceq '[deployment().location]') 'Use the selected subscription deployment region for Automation.'
Assert-True ($account.location -ceq "[parameters('location')]") 'Create the account in the region passed into the nested deployment.'
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
Assert-True ($template.variables.permissionsDeploymentId -ceq "[extensionResourceId(variables('targetScope'), 'Microsoft.Resources/deployments', variables('permissionsDeploymentName'))]") 'Resolve the permissions deployment in the target resource group.'
Assert-True ($permissionsDeployment.dependsOn -contains $accountDeploymentId) 'Permissions must wait for the Automation identity.'
$permissionParameters = $permissionsDeployment.properties.parameters
Assert-True ($permissionParameters.principalId.value -ceq $principalExpression) 'Pass the new Automation principal into the permissions deployment.'
Assert-True ($permissionParameters.policyAssignmentId.value -ceq "[variables('policyAssignmentId')]") 'Use the supplied full assignment ID to select the Reader placement.'
Assert-True ($permissionParameters.contributorRoleId.value -ceq "[variables('policyContributorRoleId')]" -and $permissionParameters.readerRoleId.value -ceq "[variables('readerRoleId')]") 'Use the existing built-in role definitions.'
Assert-True ($permissionParameters.contributorAssignmentName.value -ceq "[guid(variables('targetScope'), variables('automationAccountId'), variables('policyContributorRoleId'))]") 'Preserve the target-group role assignment name.'
Assert-True ($permissionParameters.readerAssignmentName.value -ceq "[guid(variables('policyAssignmentId'), variables('automationAccountId'), variables('readerRoleId'))]") 'Preserve the assignment-scoped Reader name.'
Assert-True ($template.variables.assignmentRelativeScope -ceq "[concat('Microsoft.Authorization/policyAssignments/', last(split(variables('policyAssignmentId'), '/')))]") 'ARM scope must be relative to the deployment, not a full /subscriptions resource ID.'
Assert-True ($permissionParameters.assignmentRelativeScope.value -ceq "[variables('assignmentRelativeScope')]") 'Pass the relative assignment scope into the target-group deployment.'
Assert-True ($template.variables.assignmentAtSubscription -ceq "[equals(toLower(variables('policyAssignmentId')), toLower(subscriptionResourceId('Microsoft.Authorization/policyAssignments', last(split(variables('policyAssignmentId'), '/')))))]") 'Only a matching subscription assignment may receive the outer Reader grant.'

$permissionResources = $permissionsDeployment.properties.template.resources
$contributor = @($permissionResources | Where-Object { $_.name -ceq "[parameters('contributorAssignmentName')]" })
$groupReader = @($permissionResources | Where-Object { $_.name -ceq "[parameters('readerAssignmentName')]" })
Assert-True ($permissionResources.Count -eq 2 -and $contributor.Count -eq 1 -and $groupReader.Count -eq 1) 'Target-group permissions deployment must contain only the contributor and conditional assignment Reader grants.'
foreach ($role in $permissionResources) {
    Assert-True ($role.type -ceq 'Microsoft.Authorization/roleAssignments' -and $role.apiVersion -ceq '2022-04-01') 'Deploy only stable RBAC role assignment resources.'
    Assert-True ($role.properties.principalType -ceq 'ServicePrincipal' -and $role.properties.principalId -ceq "[parameters('principalId')]") 'All target-group grants must use the Automation principal.'
}
Assert-True (-not $contributor[0].PSObject.Properties['scope'] -and -not $contributor[0].PSObject.Properties['condition']) 'Contributor must inherit the target resource-group deployment scope, never subscription scope.'
Assert-True ($contributor[0].properties.roleDefinitionId -ceq "[parameters('contributorRoleId')]") 'Resource Policy Contributor must be granted at the target group.'
Assert-True ($groupReader[0].condition -ceq "[equals(toLower(parameters('policyAssignmentId')), toLower(resourceId('Microsoft.Authorization/policyAssignments', last(split(parameters('policyAssignmentId'), '/')))))]") 'Only an assignment in this target group may receive the inner Reader grant.'
Assert-True ($groupReader[0].scope -ceq "[parameters('assignmentRelativeScope')]" -and $groupReader[0].properties.roleDefinitionId -ceq "[parameters('readerRoleId')]") 'Group Reader must apply only to the relative policy assignment resource.'

$subscriptionReader = $roles[0]
Assert-True ($subscriptionReader.condition -ceq "[variables('assignmentAtSubscription')]" -and $subscriptionReader.scope -ceq "[variables('assignmentRelativeScope')]") 'Subscription assignment Reader must be conditional and use a relative assignment scope.'
Assert-True ($subscriptionReader.properties.roleDefinitionId -ceq "[variables('readerRoleId')]" -and $subscriptionReader.properties.principalId -ceq $principalExpression -and $subscriptionReader.properties.principalType -ceq 'ServicePrincipal') 'Subscription assignment Reader must use the Automation principal without granting subscription-wide Reader.'
Assert-True ($subscriptionReader.name -ceq $permissionParameters.readerAssignmentName.value) 'Both Reader placements must preserve the same deterministic assignment name.'
Assert-True ($subscriptionReader.dependsOn -contains $accountDeploymentId) 'Subscription assignment Reader must wait for the Automation identity.'
Assert-True ($scheduleDeployment.dependsOn.Count -eq 3 -and $scheduleDeployment.dependsOn -contains $accountDeploymentId -and $scheduleDeployment.dependsOn -contains "[variables('permissionsDeploymentId')]" -and $scheduleDeployment.dependsOn -contains $subscriptionReader.name) 'Scheduling must wait for the runbook, target-group permissions, and conditional subscription assignment Reader.'

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
Write-Output 'PASS: Automation-only deployment, subscription-safe resource IDs, target-group RBAC deployment, relative assignment scopes, conditional Reader placement, PowerShell 7.4 runtime and attached Az.Accounts package, explicit runbook binding, hourly schedule ordering and parameters, stable resource names, and portal button URL.'
