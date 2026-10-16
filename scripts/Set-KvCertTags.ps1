#Requires -Modules Az.ConnectedMachine, Az.Resources
<#
.SYNOPSIS
    Sets the certificate-prefix tag on Arc machines from a CSV.

.DESCRIPTION
    CSV columns: Machine, Suffixes   (Suffixes is semicolon-separated in the CSV, stored comma-separated in the tag)
    Example row: web01,iis;rdp;sql
    Existing tags on the machine are preserved (Merge).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $CsvPath,
    [string] $TagName = 'KvCertSecrets'
)

foreach ($row in Import-Csv $CsvPath) {
    $suffixes = ($row.Suffixes -split ';' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) -join ','
    if ($suffixes.Length -gt 256) {
        Write-Warning "$($row.Machine): tag value exceeds 256 characters, skipping."
        continue
    }

    $machine = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -Name $row.Machine -ErrorAction Stop
    if ($PSCmdlet.ShouldProcess($row.Machine, "Set tag $TagName=$suffixes")) {
        Update-AzTag -ResourceId $machine.Id -Tag @{ $TagName = $suffixes } -Operation Merge | Out-Null
        Write-Host "$($row.Machine): $TagName=$suffixes"
    }
}
