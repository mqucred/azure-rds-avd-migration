<#
    Phase 12 — Application & Cloud-Native Runtime Validation
    App Attach + Sentinel/SOAR revalidation on hp-avd-prod-02 / cnuser01 / cnuser02

    This script is a RECORD of commands run, grouped by section, not a one-shot
    automation — several steps require manual portal confirmation (App Attach
    wizard, Entra sign-ins) and are noted as such. Review before re-running.
#>

# ============================================================
# PART A — APP ATTACH
# ============================================================

# --- A1: RBAC for AVD service principals (share scope) ---
$avdSpAppId       = "9cdead84-a844-4324-93f2-b2e6bb768d07"  # Azure Virtual Desktop
$avdArmSpAppId    = "...8d5790743a63"                        # Azure Virtual Desktop ARM Provider (use -ApplicationId, not -DisplayName, to avoid partial matches)
$shareScope       = "/subscriptions/41a2b403-5b13-4a58-8cc0-c3ec75dba78a/resourceGroups/rg-avd-prod-centralindia-001/providers/Microsoft.Storage/storageAccounts/stavdfslogixcn01/fileServices/default/fileshares/msix-apps-cn"
$accountScope     = "/subscriptions/41a2b403-5b13-4a58-8cc0-c3ec75dba78a/resourceGroups/rg-avd-prod-centralindia-001/providers/Microsoft.Storage/storageAccounts/stavdfslogixcn01"

$avdSp    = Get-AzADServicePrincipal -ApplicationId $avdSpAppId
$avdArmSp = Get-AzADServicePrincipal -ApplicationId $avdArmSpAppId

New-AzRoleAssignment -ObjectId $avdSp.Id    -RoleDefinitionName "Reader and Data Access" -Scope $shareScope
New-AzRoleAssignment -ObjectId $avdArmSp.Id -RoleDefinitionName "Reader and Data Access" -Scope $shareScope
New-AzRoleAssignment -ObjectId $avdSp.Id    -RoleDefinitionName "Reader and Data Access" -Scope $accountScope
New-AzRoleAssignment -ObjectId $avdArmSp.Id -RoleDefinitionName "Reader and Data Access" -Scope $accountScope

Get-AzRoleAssignment -Scope $accountScope | Format-Table RoleDefinitionName, ObjectId

# --- A2: Cross-share VHDX copy ---
$srcCtx = (Get-AzStorageAccount -ResourceGroupName rg-avd-prod-centralindia-001 -Name stavdfslogixprod012842).Context
$dstCtx = (Get-AzStorageAccount -ResourceGroupName rg-avd-prod-centralindia-001 -Name stavdfslogixcn01).Context

$srcSas = New-AzStorageFileSASToken -ShareName "msix-apps" -Path "NotepadPlusPlus/NotepadPlusPlus/NotepadPlusPlus.vhdx" -Permission r -ExpiryTime (Get-Date).AddHours(2) -Context $srcCtx -FullUri

Start-AzStorageFileCopy `
    -AbsoluteUri $srcSas `
    -DestShareName "msix-apps-cn" `
    -DestFilePath "NotepadPlusPlus/NotepadPlusPlus/NotepadPlusPlus.vhdx" `
    -DestContext $dstCtx

Get-AzStorageFile -ShareName "msix-apps-cn" -Path "NotepadPlusPlus/NotepadPlusPlus/NotepadPlusPlus.vhdx" -Context $dstCtx

# --- A3: Core App Attach import attempt (the failing command) ---
Import-AzWvdAppAttachPackageInfo `
    -HostPoolArmPath "/subscriptions/41a2b403-5b13-4a58-8cc0-c3ec75dba78a/resourceGroups/rg-avd-prod-centralindia-001/providers/Microsoft.DesktopVirtualization/hostpools/hp-avd-prod-02" `
    -Path "\\stavdfslogixcn01.file.core.windows.net\msix-apps-cn\NotepadPlusPlus\NotepadPlusPlus\NotepadPlusPlus.vhdx"
# Result (every attempt, verbatim):
# "Failed to retrieve access keys for storage accounts. Cannot proceed with AAD app attach workflow."

# --- A4: Isolation test against OLD proven-working storage account ---
Import-AzWvdAppAttachPackageInfo `
    -HostPoolArmPath "/subscriptions/41a2b403-5b13-4a58-8cc0-c3ec75dba78a/resourceGroups/rg-avd-prod-centralindia-001/providers/Microsoft.DesktopVirtualization/hostpools/hp-avd-prod-02" `
    -Path "\\stavdfslogixprod012842.file.core.windows.net\msix-apps\NotepadPlusPlus\NotepadPlusPlus\NotepadPlusPlus.vhdx"
# Identical error -> rules out anything storage-account-specific

# --- A5: allowSharedKeyAccess diagnostics ---
Set-AzStorageAccount -ResourceGroupName rg-avd-prod-centralindia-001 -Name stavdfslogixcn01 -AllowSharedKeyAccess $true
az storage account show --name stavdfslogixcn01 --resource-group rg-avd-prod-centralindia-001 --query "allowSharedKeyAccess"

# --- A6: Firewall diagnostics (opened then re-tightened) ---
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName rg-avd-prod-centralindia-001 -Name stavdfslogixcn01 -Bypass AzureServices
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName rg-avd-prod-centralindia-001 -Name stavdfslogixcn01 -DefaultAction Allow
# ... retest Import-AzWvdAppAttachPackageInfo here ...
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName rg-avd-prod-centralindia-001 -Name stavdfslogixcn01 -DefaultAction Deny
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName rg-avd-prod-centralindia-001 -Name stavdfslogixprod012842 -DefaultAction Deny

# --- A7: Host VM managed identity RBAC ---
az vm identity show --resource-group rg-avd-prod-centralindia-001 --name vm-avd-host-1 --query "principalId" -o tsv
New-AzRoleAssignment -ObjectId "953d37b2-af01-456d-8f28-3ce9530fac35" -RoleDefinitionName "Storage Account Key Operator Service Role" -Scope $accountScope

# --- A8: Host device object + GRP-CN-AVD-HOSTS membership ---
Connect-MgGraph -Scopes "Device.Read.All","GroupMember.ReadWrite.All"
$hostDevice = Get-MgDevice -Filter "displayName eq 'vm-avd-host-1'"
Add-AzADGroupMember -TargetGroupObjectId "f91c367d-266d-463c-b860-bd4150838d3a" -MemberObjectId $hostDevice.Id
Get-AzADGroupMember -GroupObjectId "f91c367d-266d-463c-b860-bd4150838d3a"
New-AzRoleAssignment -ObjectId "f91c367d-266d-463c-b860-bd4150838d3a" -RoleDefinitionName "Storage File Data SMB Share Reader" -Scope $accountScope

# --- A9: PRT/Kerberos check (run ON vm-avd-host-1, signed in as cnuser02) ---
# dsregcmd /status
# klist

# --- A10: Module version check ---
Get-Module -ListAvailable Az.DesktopVirtualization | Select-Object Name, Version

# --- A11: Activity Log caller-identity check ---
Get-AzActivityLog -ResourceGroupName rg-avd-prod-centralindia-001 -StartTime (Get-Date).AddHours(-6) |
    Where-Object { $_.OperationName.Value -like "*listKeys*" -and $_.ResourceId -like "*stavdfslogixcn01*" } |
    Select-Object Caller, Status, EventTimestamp


# ============================================================
# PART B — SENTINEL / SOAR REVALIDATION
# ============================================================

$sub = "41a2b403-5b13-4a58-8cc0-c3ec75dba78a"
$rg  = "rg-avd-prod-centralindia-001"
$ws  = "law-avd-secops-001"
$logicApp = "la-avd-soc-001"

# --- B1: Pull deployed analytics rule (to confirm real resource name/query/threshold) ---
az rest --method get `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/$ws/providers/Microsoft.SecurityInsights/alertRules?api-version=2024-09-01" `
  -o json | jq '.value[] | {name, displayName: .properties.displayName, enabled: .properties.enabled, query: .properties.query, queryFrequency: .properties.queryFrequency}'

# --- B2: Confirm automation rule is correctly wired ---
az rest --method get `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/$ws/providers/Microsoft.SecurityInsights/automationRules?api-version=2024-09-01" `
  -o json | jq '.value[] | {name: .properties.displayName, actions: .properties.actions}'

# --- B3: RBAC gap check — Sentinel role on workspace for the connection's identity ---
az role assignment list `
  --assignee "suadmin@anandamqucgmail.onmicrosoft.com" `
  --scope "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/$ws" `
  -o table
# (returned empty — this was the gap)

az role assignment create `
  --assignee "suadmin@anandamqucgmail.onmicrosoft.com" `
  --role "Microsoft Sentinel Responder" `
  --scope "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/$ws"

# --- B4: Confirm Azure Security Insights SP Automation Contributor on RG (ruling out the stale portal badge) ---
az ad sp list --display-name "Azure Security Insights" --query "[].{DisplayName:displayName, AppId:appId, ObjectId:id}" -o table
az role assignment list `
  --assignee "e7eb63c3-098a-44cc-a53f-c068a5c39415" `
  --resource-group $rg `
  -o table

# --- B5: Get Logic App run outputs/inputs (the real error, when run-history error fields are empty) ---
$RUN_ID = az rest --method get `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Logic/workflows/$logicApp/runs?api-version=2019-05-01&`$top=1" `
  -o json | jq -r '.value[0].name'

$OUTPUTS_URL = az rest --method get `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Logic/workflows/$logicApp/runs/$RUN_ID/actions/Update_incident?api-version=2019-05-01" `
  -o json | jq -r '.properties.outputsLink.uri'

curl -s "$OUTPUTS_URL" | jq .

# --- B6: Confirm final result via KQL (see phase12.kql for full query set) ---
# SecurityIncident | where IncidentNumber == 10 | project IncidentNumber, Status, Classification, Labels

# --- B7: Deallocate vm-avd-host-1 when not actively testing (Logic App/Sentinel work doesn't need it running) ---
az vm deallocate --resource-group $rg --name vm-avd-host-1
