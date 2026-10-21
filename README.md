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
| `policy/keyvault-extension.rules.json` | Policy rule and embedded deployment template |
| `policy/keyvault-extension.params.json` | Policy parameters (`effect`, `vaultName`, `tagName`, `pollingIntervalInS`) |
| `scripts/Set-KvCertTags.ps1` | Bulk-set the tag from a CSV |
| `scripts/Test-DeploymentTemplate.ps1` | Check deployment isolation and parity with the standalone policy |
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

For qualifying resource create/update requests, `DeployIfNotExists` evaluates after the default 10-minute delay; updates are not immediate. Tag-only PATCH requests are eligible because this policy inspects tags. Verify the actual update path used by your tooling, including `Set-KvCertTags.ps1`, in a non-production environment.

After upgrading an existing policy definition, run remediation once to stamp existing extensions. Compliance scans (scheduled or manually triggered) only report non-compliance; they do not redeploy existing resources automatically. To repair those resources without deleting the extension, create a remediation task with fresh discovery:

```powershell
az policy remediation create --name kv-ext-tag-update --policy-assignment kv-ext-arc-windows `
  -g <rg> --resource-discovery-mode ReEvaluateCompliance
```

Use a new remediation task name for subsequent runs. With `AuditIfNotExists`, changes are reported but not deployed.

Removing the machine's tag makes it out of scope; it does not uninstall the extension or remove installed certificates. Removing a prefix stops observing that secret after the extension update, but does not guarantee removal of certificates already installed. This check tracks the raw certificate tag value, not arbitrary extension-settings drift or changes to assignment parameters such as `vaultName` and `pollingIntervalInS`.

Before production use, verify in Azure that a changed tag redeploys the extension with the new `observedCertificates`, the applied marker matches the tag, and an unchanged tag remains compliant. Also verify migration from an extension without a marker and that machines without the tag remain out of scope.

## Notes

- When changing the policy, keep the rule and parameters in `azuredeploy.json` synchronized with `policy/keyvault-extension.rules.json` and `policy/keyvault-extension.params.json`. Policy expressions use `[[` instead of `[` to defer evaluation. The remediation template is stored as JSON text in `variables.extensionTemplateJson` and inserted with `json()` so ARM does not process its `copy` loop while creating the policy definition. Expressions inside that JSON text keep their original single `[`.
- Run `.\scripts\Test-DeploymentTemplate.ps1` after policy changes to check expression isolation, exact rule/parameter parity, and tag-change detection wiring. This is a local regression check, not Azure service-side validation.
- Keep `pollingIntervalInS` long (default 3600) to avoid Key Vault throttling: requests scale with certs x machines.
- If the `osName` alias is rejected, find the correct one with `az provider show --namespace Microsoft.HybridCompute --expand "resourceTypes/aliases"`.
