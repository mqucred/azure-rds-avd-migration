<#
.SYNOPSIS
    Phase 10 - Azure Files Entra Kerberos migration.
    Creates a new, cloud-native storage account alongside the existing AD-Kerberos one.
    Existing production storage account is never modified by this script.

.NOTES
    Tested against Az.Storage 9.7.2. On this version Get-AzStorageAccount does not
    reliably return AzureFilesIdentityBasedAuthentication - verification below uses
    Azure CLI instead. Update-AzStorageAccount does not exist; use Set-AzStorageAccount.
#>

$ErrorActionPreference = 'Stop'

$sub          = '41a2b403-5b13-4a58-8cc0-c3ec75dba78a'
$rg           = 'rg-avd-prod-centralindia-001'
$storageCN    = 'stavdfslogixcn01'
$storageADold = 'stavdfslogixprod012842'   # reference only - never modified by this script

# ---------------------------------------------------------------------------
# 1. New storage account
# ---------------------------------------------------------------------------
Write-Host "`n=== 1. Creating storage account $storageCN ===" -ForegroundColor Cyan
New-AzStorageAccount -ResourceGroupName $rg -Name $storageCN `
    -Location centralindia -SkuName Standard_LRS -Kind StorageV2

# ---------------------------------------------------------------------------
# 2. Enable Microsoft Entra Kerberos
# ---------------------------------------------------------------------------
Write-Host "`n=== 2. Enabling Entra Kerberos ===" -ForegroundColor Cyan
Set-AzStorageAccount -ResourceGroupName $rg -Name $storageCN `
    -EnableAzureActiveDirectoryKerberosForFile $true

# ---------------------------------------------------------------------------
# 3. Verify identity source (az cli - see Known issues in README)
# ---------------------------------------------------------------------------
Write-Host "`n=== 3. Verifying identity source (expect AADKERB) ===" -ForegroundColor Cyan
az storage account show --name $storageCN --resource-group $rg `
    --query "azureFilesIdentityBasedAuthentication"

# ---------------------------------------------------------------------------
# 4. Create shares
# ---------------------------------------------------------------------------
Write-Host "`n=== 4. Creating shares ===" -ForegroundColor Cyan
$ctx = (Get-AzStorageAccount -ResourceGroupName $rg -Name $storageCN).Context
New-AzStorageShare -Name profiles-cn  -Context $ctx -QuotaGiB 50
New-AzStorageShare -Name msix-apps-cn -Context $ctx -QuotaGiB 20

# ---------------------------------------------------------------------------
# 5. RBAC - profiles share
# ---------------------------------------------------------------------------
Write-Host "`n=== 5. Assigning GRP-CN-AVD-USERS -> SMB Share Contributor ===" -ForegroundColor Cyan
New-AzRoleAssignment -ObjectId (Get-AzADGroup -DisplayName "GRP-CN-AVD-USERS").Id `
    -RoleDefinitionName "Storage File Data SMB Share Contributor" `
    -Scope "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storageCN"

# ---------------------------------------------------------------------------
# 6. Cloud-native hosts group + RBAC for msix-apps share
# ---------------------------------------------------------------------------
Write-Host "`n=== 6. Creating GRP-CN-AVD-HOSTS and assigning Reader ===" -ForegroundColor Cyan
New-AzADGroup -DisplayName "GRP-CN-AVD-HOSTS" -MailNickname "GRP-CN-AVD-HOSTS"

# Freshly-created Entra groups can return ServiceUnavailable on the first RBAC
# attempt (Entra -> Azure RBAC propagation lag). Retry once after a short wait.
$maxAttempts = 3
for ($i = 1; $i -le $maxAttempts; $i++) {
    try {
        New-AzRoleAssignment -ObjectId (Get-AzADGroup -DisplayName "GRP-CN-AVD-HOSTS").Id `
            -RoleDefinitionName "Storage File Data SMB Share Reader" `
            -Scope "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storageCN"
        break
    } catch {
        if ($i -eq $maxAttempts) { throw }
        Write-Host "Attempt $i failed (likely propagation lag) - retrying in 30s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
Write-Host "`n=== Verification: RBAC on $storageCN ===" -ForegroundColor Cyan
Get-AzRoleAssignment -Scope "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storageCN" |
    Select-Object DisplayName, RoleDefinitionName

Write-Host "`n=== Confirming old AD storage account is untouched ===" -ForegroundColor Cyan
az storage account show --name $storageADold --resource-group $rg `
    --query "azureFilesIdentityBasedAuthentication"

Write-Host "`nPhase 10 complete. Expect: directoryServiceOptions=AADKERB on $storageCN, directoryServiceOptions=AD on $storageADold (unchanged)." -ForegroundColor Green
