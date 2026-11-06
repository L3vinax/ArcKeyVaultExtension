# Arc Key Vault certificate policy (Preview)

> **In development:** This project is in preview. Validate it in a non-production environment before production use.

Azure Policy (`DeployIfNotExists`) that installs the **KeyVaultForWindows** extension on Azure Arc-enabled Windows servers and configures it to monitor several certificates per machine.

## How it works

- Each Arc machine gets a tag (default `KvCertSecrets`) containing a comma-separated list of secret prefixes, e.g. `iis,rdp,sql`.
- For every prefix, the extension observes the Key Vault secret `<prefix>-<machine name>`. The machine name is lowercased and dots become dashes (`Web01.contoso.com` -> `web01-contoso-com`).
  - Tag `iis,rdp` on `web01` -> `.../secrets/iis-web01` and `.../secrets/rdp-web01`.
- Machines without the tag are ignored. Non-Windows machines are ignored.
- Certificates are installed in `LocalMachine\MY` with `linkOnRenewal` enabled.
- Only one `KeyVaultForWindows` extension can exist per machine, so all certs share one `observedCertificates` array.
- The extension's `forceUpdateTag` property records the applied certificate tag value. A different or missing value makes the extension non-compliant, allowing policy to redeploy it with the current list without deleting it.

## Layout

| Path | Purpose |
|---|---|
| `azuredeploy.json` | Subscription-level ARM template for the Deploy to Azure button |
| `azuredeploy-remediation.json` | Separate subscription-level ARM template for hourly Automation remediation |
| `policy/keyvault-extension.rules.json` | Policy rule and embedded deployment template |
| `policy/keyvault-extension.params.json` | Policy parameters (`effect`, `vaultName`, `tagName`, `pollingIntervalInS`) |
| `scripts/Set-KvCertTags.ps1` | Bulk-set the tag from a CSV |
| `scripts/Deploy-KvCertRemediationAutomation.ps1` | Deploy an optional hourly Automation account, runbook, identity, permissions, and schedule |
| `scripts/Invoke-KvCertRemediation.ps1` | Managed-identity runbook that remediates one assignment in a resource group |
| `scripts/Test-DeploymentTemplate.ps1` | Check deployment isolation and parity with the standalone policy |
| `scripts/Test-KvCertRemediation.ps1` | Isolated runbook and automation deployment regression tests (no Azure login needed) |
| `scripts/Test-RemediationDeploymentTemplate.ps1` | Check Automation button isolation, permissions, runbook source, and schedule wiring |
| `scripts/machines.sample.csv` | Example CSV |

## Prerequisites

1. Secrets exist in the vault, named `<prefix>-<machine>` (secret, not certificate, so the private key is included).
2. Each Arc machine's system-assigned identity can read them: add the identities to an Entra group and grant **Key Vault Secrets User** on the vault (RBAC) or get/list secrets (access policy).
3. Tag values are limited to 256 characters.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FL3vinax%2FArcKeyVaultExtension%2Fmain%2Fazuredeploy.json)

### Azure portal

1. Select **Deploy to Azure**, sign in, and choose the subscription and deployment location. The location stores deployment metadata; the policy definition is subscription-wide.
2. Keep the default policy definition name (`kv-ext-arc-windows`) or choose another name, then select **Review + create** and **Create**. Reusing an existing name updates that definition.
3. After deployment, assign the definition using step 2 below or **Azure Policy > Definitions > Assign policy**. Supply `vaultName`, choose the assignment scope, and enable a system-assigned managed identity with the **Azure Connected Machine Resource Administrator** role at that scope.
4. Tag machines and create a remediation task for existing machines (steps 3 and 4 below).

The button creates **only the policy definition**, not an assignment, managed identity, role assignment, Key Vault, or certificates. You need subscription-level `Microsoft.Authorization/policyDefinitions/write` and `Microsoft.Resources/deployments/*` permissions (for example, **Resource Policy Contributor**). Machines still need the Key Vault access described in the prerequisites.

The button requires `azuredeploy.json` to be published on this repository's `main` branch and publicly accessible. If you fork the repository, update the button's template URL.

### Azure CLI

Skip step 1 if you already deployed the definition with the button. If you chose a different definition name, use it in `--policy` in step 2.

```powershell
# 1. Definition
az policy definition create --name kv-ext-arc-windows `
  --display-name "Deploy Key Vault extension to Arc Windows servers (tag-driven secrets)" `
  --mode Indexed `
  --rules .\policy\keyvault-extension.rules.json `
  --params .\policy\keyvault-extension.params.json

# 2. Assignment (managed identity is required for DeployIfNotExists)
az policy assignment create --name kv-ext-arc-windows --policy kv-ext-arc-windows `
  --scope /subscriptions/<subId>/resourceGroups/<rg> `
  --mi-system-assigned --location <region> `
  --role "Azure Connected Machine Resource Administrator" `
  --identity-scope /subscriptions/<subId>/resourceGroups/<rg> `
  --params '{ "vaultName": { "value": "kv-ocscerts" } }'

# 3. Tag machines
.\scripts\Set-KvCertTags.ps1 -ResourceGroupName <rg> -CsvPath .\scripts\machines.local.csv -WhatIf

# 4. Remediate machines that already exist (policy only auto-deploys to new/changed resources)
az policy remediation create --name kv-ext-remediate --policy-assignment kv-ext-arc-windows -g <rg>
```

## Changing a machine's certificate list

Change the machine's certificate tag to the new comma-separated prefix list. The policy compares it with the extension's `properties.forceUpdateTag` and updates the existing extension when they differ. This property is an extension handler update marker, not an Azure resource tag. An unchanged value remains compliant.

For qualifying resource create/update requests, `DeployIfNotExists` evaluates after the default 10-minute delay; updates are not immediate. Do not assume all tag edits trigger deployment. The Azure portal Tags page can use `Microsoft.Resources/tags/write`; in testing, this path did not automatically update the extension, but explicit remediation succeeded without uninstalling it. The bulk-tag script also uses the separate tags API (`Update-AzTag`). Use explicit or scheduled remediation for these workflows.

After upgrading an existing policy definition, run remediation once to stamp existing extensions. Compliance scans (scheduled or manually triggered) only report non-compliance; they do not redeploy existing resources automatically. To repair those resources without deleting the extension, create a remediation task with fresh discovery:

```powershell
az policy remediation create --name kv-ext-tag-update --policy-assignment kv-ext-arc-windows `
  -g <rg> --resource-discovery-mode ReEvaluateCompliance
```

Use a new remediation task name for subsequent runs. With `AuditIfNotExists`, changes are reported but not deployed.

The policy definition name, assignment name, and assignment display name can differ. Use the **full assignment resource ID** from Azure Policy > Assignments (or the assignment linked from a successful remediation task), rather than assuming the example assignment name matches your environment.

Removing the machine's tag makes it out of scope; it does not uninstall the extension or remove installed certificates. Removing a prefix stops observing that secret after the extension update, but does not guarantee removal of certificates already installed. This check tracks the raw certificate tag value, not arbitrary extension-settings drift or changes to assignment parameters such as `vaultName` and `pollingIntervalInS`.

Before production use, verify in Azure that a changed tag redeploys the extension with the new `observedCertificates`, the applied marker matches the tag, and an unchanged tag remains compliant. Also verify migration from an extension without a marker and that machines without the tag remain out of scope.

## Optional hourly remediation

Both Automation deployment methods configure a **dedicated Automation account** with a system-assigned identity, a **PowerShell 7.4 runtime environment** named `KvCertRemediation-PowerShell74`, an attached `Az.Accounts` package (minimum 5.3.3), a published runbook explicitly linked to that environment, and an hourly UTC schedule. Az.Accounts is attached to the named runtime environment, not imported into the account's legacy Modules collection. The original Deploy to Azure button remains policy-definition-only.

Each run creates a uniquely named remediation task with `ReEvaluateCompliance`, so it does not wait for the approximately daily policy compliance scan. Only non-compliant resources eligible for the assignment are deployed. A changed tag should be discovered on the next hourly run, plus Azure evaluation, deployment, and certificate installation time; this is not an exact one-hour installation guarantee.

### Prerequisites and deployment

- An existing standalone certificate policy assignment at the target resource group or subscription, with effect `DeployIfNotExists` and a managed identity authorized to deploy the Arc extension. Initiative and management-group assignments are not supported by this script.
- Both the Automation resource group and target resource group already exist in the same subscription. Use a separate account for each assignment/target-group pair; do not attach additional schedules or start concurrent manual jobs for this runbook.
- The deploying user needs Automation resource management permissions in the Automation resource group, permission to read the assignment, and permission to create role assignments at the target resource group and the policy assignment resource (for example, Owner, or Contributor plus Role Based Access Control Administrator at the relevant scopes).
- For script deployment only, install `Az.Accounts`, `Az.Automation`, and `Az.Resources` on the workstation. Only `Az.Accounts` is needed inside Automation; both deployment methods attach version 5.3.3 to the PowerShell 7.4 runtime environment. The script reuses a successfully imported package at version 5.3.3 or later.

### Deploy Automation through the Azure portal

[![Deploy hourly remediation to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FL3vinax%2FArcKeyVaultExtension%2Fmain%2Fazuredeploy-remediation.json)

This is a **separate deployment** from the policy-definition button above. It creates the Automation account, system-assigned identity, PowerShell 7.4 runtime environment with an attached Az.Accounts package, published runbook linked to that environment, scoped role assignments, and hourly schedule. It does **not** create resource groups, a policy definition or assignment, Key Vault access, or certificates.

1. First create the certificate policy assignment with `DeployIfNotExists` and its authorized managed identity. Confirm the assignment is standalone and scoped to the target resource group or subscription.
2. Select **Deploy hourly remediation to Azure**, choose the subscription containing both existing resource groups, and select a **Region** supporting Azure Automation PowerShell 7.4 runtime environments. This region is used for both subscription deployment metadata and the Automation account/runtime; there is no separate Automation Location field.
3. Enter the **Automation Resource Group Name** and a **new, dedicated Automation Account Name**. The account uses the selected Region, regardless of the existing resource group's metadata location.
4. Enter the **Target Resource Group Name** containing the Arc machines.
5. Enter **Policy Assignment Id** using the **full assignment resource ID**, copied from Azure Policy > Assignments. For a subscription assignment, use `/subscriptions/<subscription-guid>/providers/Microsoft.Authorization/policyAssignments/<assignment-name>`. For a resource-group assignment, use `/subscriptions/<subscription-guid>/resourceGroups/<target-rg>/providers/Microsoft.Authorization/policyAssignments/<assignment-name>`. The assignment must belong to the selected subscription and be scoped to that subscription or the target group. This is one required text field with no 64-character limit; do not enter only the subscription/resource-group scope, assignment name, policy definition name, or display name. The supplied ID is used unchanged for Reader permissions and the runbook's `PolicyAssignmentId`.
6. Leave **Runbook Content Uri** at its default for this repository, or use a trusted public HTTPS URL from your fork or a pinned commit. This code runs with the Automation identity's permissions; review alternative sources before deploying.
7. Select **Review + create** and **Create**. Runtime package import can take several minutes. The hourly schedule is created after the account/runtime/package/runbook deployment and both role grants complete, with its first start approximately 10 minutes later.
8. Check the deployment outputs for the account, assignment, and target IDs. In Automation > Runtime environments > `KvCertRemediation-PowerShell74`, verify the language/version is **PowerShell 7.4** and the attached **Az.Accounts** package shows **Succeeded** at version **5.3.3**. Verify the runbook is **Published** and linked to this runtime environment, the schedule is enabled and linked with the correct parameters, and the first scheduled job succeeds.

In addition to the scoped resource/role permissions above, portal deployment requires `Microsoft.Resources/deployments/*` at the subscription and Automation resource group. The Reader grant is limited to the assignment resource, not the entire subscription. The template cannot perform the deployment script's assignment/effect/identity preflight checks, so verify those prerequisites before deploying.

If portal validation reports that your Automation resource group name "is not valid subscription identifier", use the updated template and reopen the Deploy to Azure button to load it again. This is a template resource-ID construction error, not a requirement to enter a subscription GUID in **Automation Resource Group Name**. Keep the existing resource group name. The template builds its ID with `subscriptionResourceId` and then uses `extensionResourceId` for the Automation account and nested deployment references; `resourceId` is used only inside the resource-group-scoped nested templates.

If validation reports that `Microsoft.Authorization/roleAssignments/<guid>` "is not defined in the template", reload the updated template. The schedule deployment depends on the scoped role assignments by their declared GUID resource names, not reconstructed scoped IDs. This preserves the required ordering without changing either grant's scope or role; no manual role assignment or broader permissions are needed to correct this template dependency error.

Use this button for **initial deployment to a new account**. ARM does not perform the script's conflicting-schedule checks; do not reuse it to retarget an existing account. For safe repeat deployments and local runbook updates, use the script below with the same assignment and target group. It preserves the existing schedule and detects conflicting parameters.

The portal's Region normally controls only the subscription deployment metadata location. This template also passes `deployment().location` into the Automation deployment, so one selection controls both. Choose the account's existing region if retrying a partially completed deployment with the same account name; Automation accounts cannot be moved between regions by redeploying them. The PowerShell deployment script still accepts an explicit `Location` because it does not use this portal deployment.

The button works only after `azuredeploy-remediation.json` **and** `scripts/Invoke-KvCertRemediation.ps1` are publicly published on `main`. The existing policy-definition button is unchanged. For a fork, update both the button's template URL and the runbook source URL. Publishing source changes does not update already-deployed runbooks; redeploy them using the script.

### Deploy or update Automation with PowerShell

```powershell
Install-Module Az.Accounts, Az.Automation, Az.Resources -Scope CurrentUser
Connect-AzAccount

.\scripts\Deploy-KvCertRemediationAutomation.ps1 `
  -SubscriptionId '<subscription-guid>' `
  -AutomationResourceGroupName '<automation-rg>' `
  -AutomationAccountName '<unique-automation-account-name>' `
  -Location '<azure-region>' `
  -TargetResourceGroupName 'rg-arc-01' `
  -PolicyAssignmentId '/subscriptions/<subscription-guid>/providers/Microsoft.Authorization/policyAssignments/<actual-assignment-name>'
```

For a resource-group assignment, its ID includes `/resourceGroups/<rg>` before `/providers/Microsoft.Authorization/policyAssignments/`. The script validates the assignment scope, refuses initiative assignments and explicitly non-deploying effects, and does not create or change the policy assignment.

The Automation identity receives **Resource Policy Contributor** at the target resource group and **Reader** at the supplied assignment resource. Resource Policy Contributor is a built-in convenience role with broader policy-management permissions than this runbook needs; use a dedicated account. The **policy assignment's identity**, not the Automation identity, still performs extension deployments. No Key Vault access is granted to the Automation identity.

The script uses the ARM RBAC REST API to list and create these grants. Some `Az.Resources` versions reject subscription-level policy assignment resource IDs as `Get-AzRoleAssignment`/`New-AzRoleAssignment` scopes. This does not make the policy assignment ID invalid, and the script does not work around it by granting subscription-wide Reader access. If an older copy fails with "Scope ... should begin with ... /resourceGroups", use the updated deployment script and rerun with the same full assignment ID and inputs; it reuses the account and existing grants.

A new schedule starts about 10 minutes after deployment and repeats every hour in UTC. Allow time for new role assignments to propagate. Rerunning with the same inputs republishes the local runbook without duplicating the schedule link or role assignments. An existing account must already have a system-assigned identity. A conflicting target or an invalid/disabled existing schedule fails explicitly instead of silently retargeting it.

The script uses the Automation REST API `2024-10-23` to configure the named PowerShell 7.4 runtime and its attached Az.Accounts package. It waits up to 20 minutes for package import, rejects failed or malformed import responses, imports the local runbook as a draft, explicitly binds the draft to the runtime, and only then publishes it. Rerunning with the same inputs also migrates a runbook deployed by the earlier PowerShell 5.1 script to the new runtime without changing its schedule or remediation scope. Legacy account modules are left untouched. Use the account's existing region for `Location` when updating.

### Monitoring and verification

- In Automation > Runbooks > `Invoke-KvCertRemediation` > Jobs, inspect output and errors. Each run logs the remediation name and waits up to 45 minutes for it to finish. Failed/canceled remediation or failed deployments fail the job, including partial deployment failures.
- If remediation is already active for this assignment in the target resource group, the next job logs a skip rather than creating another task. This is an active-task check, not a distributed lock; keep one schedule and avoid concurrent manual starts. Paginated remediation listings are followed.
- A timeout fails the job but does **not** cancel the Azure remediation; subsequent jobs skip while that task remains active. Inspect long-running tasks in Azure Policy. Previous failed tasks are warned about before a new retry.
- Set up Azure Monitor alerts for failed/suspended Automation jobs and inspect Azure Policy > Remediation > Deployments for the underlying deployment errors. Alerts are not created by this script.
- For an end-to-end test, add an existing accessible secret prefix to a machine's tag, wait for a scheduled job, and verify its task succeeds, the extension's `forceUpdateTag` and `observedCertificates` match, and the certificate appears in `Cert:\LocalMachine\My`. Then leave the tag unchanged and verify the next remediation has no unnecessary extension deployments.
- Disable the `KvCertRemediation-Hourly` schedule to stop automatic remediation. Existing tasks continue; disabling the schedule does not remove extensions or certificates. Automation job runtime and Azure operations can incur charges.

Run the local regression checks after automation or policy changes:

```powershell
.\scripts\Test-KvCertRemediation.ps1
.\scripts\Test-DeploymentTemplate.ps1
.\scripts\Test-RemediationDeploymentTemplate.ps1
```

The automation tests replace Azure commands with local mocks. They validate request payloads, PowerShell 7.4 runtime creation, attached package readiness/failures, binding before publication, scheduling, repeat deployment, overlap handling, pagination, and failure reporting. The Automation template test checks deployment isolation, scoped roles, the runtime version and attached package, the published runbook source/binding, and schedule dependencies/parameters. These local checks do not validate Azure RBAC propagation or service-side deployment. Complete the end-to-end scheduled-job test above before production use.

## Notes

- When changing the policy, keep the rule and parameters in `azuredeploy.json` synchronized with `policy/keyvault-extension.rules.json` and `policy/keyvault-extension.params.json`. Policy expressions use `[[` instead of `[` to defer evaluation. The remediation template is stored as JSON text in `variables.extensionTemplateJson` and inserted with `json()` so ARM does not process its `copy` loop while creating the policy definition. Expressions inside that JSON text keep their original single `[`.
- Run `.\scripts\Test-DeploymentTemplate.ps1` after policy changes to check expression isolation, exact rule/parameter parity, and tag-change detection wiring. This is a local regression check, not Azure service-side validation.
- Keep `pollingIntervalInS` long (default 3600) to avoid Key Vault throttling: requests scale with certs x machines.
- If the `osName` alias is rejected, find the correct one with `az provider show --namespace Microsoft.HybridCompute --expand "resourceTypes/aliases"`.
