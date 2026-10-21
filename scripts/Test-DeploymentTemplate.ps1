[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$template = Get-Content -Raw (Join-Path $root 'azuredeploy.json') | ConvertFrom-Json
$rule = Get-Content -Raw (Join-Path $root 'policy\keyvault-extension.rules.json') | ConvertFrom-Json
$parameters = Get-Content -Raw (Join-Path $root 'policy\keyvault-extension.params.json') | ConvertFrom-Json

if ($template.'$schema' -ne 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#') {
    throw 'The button must deploy at subscription scope.'
}
if ($template.resources.Count -ne 1 -or $template.resources[0].type -ne 'Microsoft.Authorization/policyDefinitions') {
    throw 'The button must deploy only a policy definition.'
}

$definition = $template.resources[0]
$embeddedRule = $definition.properties.policyRule
$deployment = $embeddedRule.then.details.deployment.properties
if ($deployment.template -cne "[json(variables('extensionTemplateJson'))]") {
    throw 'The remediation template must be materialized from JSON to prevent premature copy-loop evaluation.'
}
if ($template.variables.extensionTemplateJson -isnot [string] -or -not $template.variables.extensionTemplateJson.StartsWith('{')) {
    throw 'The remediation template must be stored as literal JSON text.'
}

# ARM processes copy blocks before policy evaluation, even when their expressions use [[.
$outerJson = $template | ConvertTo-Json -Depth 100 -Compress
if ($outerJson -match '"copy"\s*:') {
    throw 'A copy block is exposed to the outer deployment instead of isolated in JSON text.'
}

$deployment.template = $null
$escapedRule = $embeddedRule | ConvertTo-Json -Depth 100 -Compress
if ($escapedRule -match '"\[(?!\[)') {
    throw 'A policy expression is not escaped for the outer ARM deployment.'
}
$resolvedRule = ($escapedRule -replace '"\[\[', '"[') | ConvertFrom-Json
$resolvedRule.then.details.deployment.properties.template = $template.variables.extensionTemplateJson | ConvertFrom-Json

$resolvedJson = $resolvedRule | ConvertTo-Json -Depth 100 -Compress
$originalJson = $rule | ConvertTo-Json -Depth 100 -Compress
if ($resolvedJson -cne $originalJson) {
    throw 'The deployed policy rule does not match the standalone policy rule.'
}
$embeddedParameters = $definition.properties.parameters | ConvertTo-Json -Depth 100 -Compress
$originalParameters = $parameters | ConvertTo-Json -Depth 100 -Compress
if ($embeddedParameters -cne $originalParameters) {
    throw 'The deployed policy parameters do not match the standalone policy parameters.'
}

$tagValueExpression = "[field(concat('tags[', parameters('tagName'), ']'))]"
$tagChecks = @($rule.then.details.existenceCondition.allOf | Where-Object {
    $_.field -ceq 'Microsoft.HybridCompute/machines/extensions/forceUpdateTag'
})
if ($tagChecks.Count -ne 1 -or $tagChecks[0].equals -cne $tagValueExpression) {
    throw 'Extension compliance must compare forceUpdateTag with the parent machine certificate tag.'
}

$remediation = $rule.then.details.deployment.properties
if ($remediation.parameters.certSuffixes.value -cne $tagValueExpression) {
    throw 'Remediation must receive the same certificate tag value used by the compliance check.'
}
$extensions = @($remediation.template.resources | Where-Object {
    $_.type -ceq 'Microsoft.HybridCompute/machines/extensions'
})
if ($extensions.Count -ne 1 -or $extensions[0].properties.forceUpdateTag -cne "[parameters('certSuffixes')]") {
    throw 'Remediation must stamp the certificate tag value into extension forceUpdateTag.'
}

Write-Output 'PASS: subscription scope, definition-only deployment, isolated copy loop, escaped expressions, exact policy rule/parameter parity, and tag-change detection wiring.'
