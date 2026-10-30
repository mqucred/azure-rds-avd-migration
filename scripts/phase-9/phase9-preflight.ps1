<#
.SYNOPSIS
    Phase 9 - Cloud-native identity & dependency preflight.
    Discovery and evidence only. No resource changes, no deletion, no storage auth switch.

.NOTES
    Run 9.1, 9.2, 9.5 from Cloud Shell or a workstation with Az PowerShell + an account
    holding Owner/Reader at subscription scope.
    Run 9.3 and 9.4 from vm-avd-host-0 (domain-joined) - Cloud Shell cannot reach the
    storage data plane here (firewall Deny + Cloud Shell's MSI has no SMB share RBAC).
#>

$ErrorActionPreference = 'Stop'

$sub        = '41a2b403-5b13-4a58-8cc0-c3ec75dba78a'
$rgOnPrem   = 'rg-onprem-prod-centralindia-001'
$rgAvd      = 'rg-avd-prod-centralindia-001'
$storageAD  = 'stavdfslogixprod012842'
$law        = 'law-avd-secops-001'

# ---------------------------------------------------------------------------
# 9.1 - Current Azure resources and AVD state
# ---------------------------------------------------------------------------
Write-Host "`n=== 9.1 VM power states ===" -ForegroundColor Cyan
Get-AzVM -ResourceGroupName $rgOnPrem -Status | Select-Object Name, PowerState
Get-AzVM -ResourceGroupName $rgAvd    -Status | Select-Object Name, PowerState

Write-Host "`n=== 9.1 Storage firewall rules ===" -ForegroundColor Cyan
Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $rgAvd -AccountName $storageAD

Write-Host "`n=== 9.1 AVD host pool / app groups / workspace ===" -ForegroundColor Cyan
Get-AzWvdHostPool -ResourceGroupName $rgAvd | Select-Object Name
Get-AzWvdApplicationGroup -ResourceGroupName $rgAvd | Select-Object Name, ApplicationGroupType
Get-AzWvdWorkspace -ResourceGroupName $rgAvd | Select-Object Name

Write-Host "`n=== 9.1 Sentinel automation rule ===" -ForegroundColor Cyan
Get-AzSentinelAutomationRule -ResourceGroupName $rgAvd -WorkspaceName $law | Select-Object DisplayName

# ---------------------------------------------------------------------------
# 9.2 - User and identity model
# ---------------------------------------------------------------------------
Write-Host "`n=== 9.2 Existing hybrid users (expect populated onPremisesSecurityIdentifier) ===" -ForegroundColor Cyan
Get-AzADUser -UserPrincipalName "avduser01@anandamqucgmail.onmicrosoft.com" `
    -Select "onPremisesSyncEnabled,onPremisesSecurityIdentifier,onPremisesDomainName" | Format-List *
Get-AzADUser -UserPrincipalName "avduser02@anandamqucgmail.onmicrosoft.com" `
    -Select "onPremisesSyncEnabled,onPremisesSecurityIdentifier,onPremisesDomainName" | Format-List *

Write-Host "`n--> Create cnuser01 / cnuser02 (cloud-only) and GRP-CN-AVD-USERS in the Entra portal or via Graph before continuing." -ForegroundColor Yellow

Write-Host "`n=== 9.2 Verify cloud-only users (expect EMPTY onPremisesSecurityIdentifier) ===" -ForegroundColor Cyan
Get-AzADUser -UserPrincipalName "cnuser01@anandamqucgmail.onmicrosoft.com" `
    -Select "displayName,onPremisesSyncEnabled,onPremisesSecurityIdentifier" | Format-List *
Get-AzADUser -UserPrincipalName "cnuser02@anandamqucgmail.onmicrosoft.com" `
    -Select "displayName,onPremisesSyncEnabled,onPremisesSecurityIdentifier" | Format-List *

Write-Host "`n=== 9.2 GRP-CN-AVD-USERS membership ===" -ForegroundColor Cyan
Get-AzADGroup -DisplayName "GRP-CN-AVD-USERS" | Select-Object DisplayName, Id, SecurityEnabled
Get-AzADGroupMember -GroupObject (Get-AzADGroup -DisplayName "GRP-CN-AVD-USERS") | Select-Object DisplayName, Id

# ---------------------------------------------------------------------------
# 9.3 / 9.4 - RUN FROM vm-avd-host-0, not Cloud Shell
# ---------------------------------------------------------------------------
<#
# 9.3 - NTFS ACL baseline on the AD-Kerberos profiles share
icacls "\\stavdfslogixprod012842.file.core.windows.net\profiles"

# 9.4 - Session host join state and FSLogix config
dsregcmd /status
Get-ItemProperty -Path "HKLM:\SOFTWARE\FSLogix\Profiles" | Select-Object VHDLocations, Enabled, FlipFlopProfileDirectoryName
#>

# ---------------------------------------------------------------------------
# 9.5 - MSIX / App Attach dependencies
# ---------------------------------------------------------------------------
Write-Host "`n=== 9.5 App Attach package ===" -ForegroundColor Cyan
Get-AzWvdAppAttachPackage -ResourceGroupName $rgAvd | Select-Object Name, ProvisioningState

Write-Host "`n=== 9.5 Storage account RBAC (covers msix-apps share access) ===" -ForegroundColor Cyan
Get-AzRoleAssignment -Scope "/subscriptions/$sub/resourceGroups/$rgAvd/providers/Microsoft.Storage/storageAccounts/$storageAD" |
    Select-Object DisplayName, RoleDefinitionName

Write-Host "`nPhase 9 discovery complete. Review output above against README.md Verification section before declaring GO for Phase 10." -ForegroundColor Green
