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

The policy's existence check only tests that the extension exists, not its settings. After changing a tag on a machine that already has the extension, delete the extension and re-run remediation, or update it directly:

```powershell
az connectedmachine extension delete --machine-name <name> -g <rg> --name KeyVaultForWindows -y
az policy remediation create --name kv-ext-remediate-<name> --policy-assignment kv-ext-arc-windows -g <rg>
```

## Notes

- When changing the policy, keep the rule and parameters in `azuredeploy.json` synchronized with `policy/keyvault-extension.rules.json` and `policy/keyvault-extension.params.json`. Policy expressions use `[[` instead of `[` to defer evaluation. The remediation template is stored as JSON text in `variables.extensionTemplateJson` and inserted with `json()` so ARM does not process its `copy` loop while creating the policy definition. Expressions inside that JSON text keep their original single `[`.
- Run `.\scripts\Test-DeploymentTemplate.ps1` after policy changes to check expression isolation and exact rule/parameter parity. This is a local regression check, not Azure service-side validation.
- Keep `pollingIntervalInS` long (default 3600) to avoid Key Vault throttling: requests scale with certs x machines.
- If the `osName` alias is rejected, find the correct one with `az provider show --namespace Microsoft.HybridCompute --expand "resourceTypes/aliases"`.
