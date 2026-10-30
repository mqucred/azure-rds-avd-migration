<#
Phase 11: Entra-Only AVD + FSLogix Cutover
Run storage/Entra sections from Cloud Shell (admin context).
Run host sections on vm-avd-host-1 as azlabadmin (elevated).
Replace placeholders before running.
#>

# ===== Variables =====
$ResourceGroup   = "rg-avd-prod-centralindia-001"
$StorageAccount  = "stavdfslogixcn01"
$ShareName       = "profiles-cn"
$StorageAppId    = "<storage-app-id>"      # from Phase 10 / Get-AzADServicePrincipal
$SubscriptionId  = "<subscription-id>"

# =========================================================
# SECTION 1 — Storage account: default share permission
# Run in: Cloud Shell
# Mandatory for cloud-only identities. Per-user RBAC alone is not sufficient —
# Entra Kerberos needs an account-level fallback permission to authorize SMB.
# =========================================================
az storage account update `
    --name $StorageAccount `
    --resource-group $ResourceGroup `
    --default-share-permission StorageFileDataSmbShareContributor

# Verify
az storage account show `
    --name $StorageAccount `
    --resource-group $ResourceGroup `
    --query "azureFilesIdentityBasedAuthentication"


# =========================================================
# SECTION 2 — Tag the storage account's service principal + app registration
# Run in: Cloud Shell
# Mandatory for cloud-only identity support (combined on-prem + cloud group SIDs).
# =========================================================
$sp = Get-AzADServicePrincipal -ApplicationId $StorageAppId
Update-AzADServicePrincipal -ObjectId $sp.Id `
    -Tag @("WindowsAzureActiveDirectoryIntegratedApp", "kdc_enable_cloud_group_sids")

$app = Get-AzADApplication -ApplicationId $StorageAppId
$app.Tag   # confirm tag present here too (separate object from the SP)


# =========================================================
# SECTION 3 — Grant Entra admin consent on the storage app registration
# Run in: Cloud Shell
# *** THIS IS THE STEP THAT ACTUALLY UNBLOCKS AUTHENTICATION ***
# Without this, ticket issuance silently fails with no client-side error —
# device-level Kerberos state (PRT, CloudTgt, referral TGT) all look healthy,
# but the client never progresses to requesting a service ticket for the
# storage SPN. Confirmed via Entra sign-in logs showing Error 90008.
# =========================================================
az ad app permission admin-consent --id $StorageAppId


# =========================================================
# SECTION 4 — Host-side: Cloud Kerberos registry keys
# Run on: vm-avd-host-1, elevated PowerShell, as azlabadmin
# =========================================================
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount" `
    -Name "CloudKerberosTicketRetrievalEnabled" -Value 1 -PropertyType DWORD -Force

New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount" `
    -Name "LoadCredKeyFromProfile" -Value 1 -PropertyType DWORD -Force

New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters" `
    -Name "CloudKerberosTicketRetrievalEnabled" -Value 1 -PropertyType DWORD -Force

# Reboot required for registry changes to take effect
Restart-Computer -Force


# =========================================================
# SECTION 5 — Host pool: Entra-join RDP property
# Run in: Cloud Shell
# Mandatory for Entra-joined-only session hosts. Without it, sign-in fails
# with a generic "check your username and password" error.
# =========================================================
# Append to existing custom RDP property string on hp-avd-prod-02
az desktopvirtualization hostpool update `
    --resource-group $ResourceGroup `
    --name "hp-avd-prod-02" `
    --custom-rdp-property "targetisaadjoined:i:1"


# =========================================================
# SECTION 6 — Verification (run AFTER full sign-out/sign-in as the test user)
# =========================================================

# --- As the test user (e.g. cnuser02), non-admin session, on vm-avd-host-1 ---
#   dsregcmd /status
#   klist cloud_debug
#   klist purge
#   net use Z: \\stavdfslogixcn01.file.core.windows.net\profiles-cn
#   klist

# --- As azlabadmin, on vm-avd-host-1 ---
Get-WinEvent -LogName "Microsoft-FSLogix-Apps/Operational" -MaxEvents 20 |
    Where-Object { $_.Message -match "cnuser02" } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List |
    Out-File "C:\Users\azlabadmin\Desktop\phase11-fslogix-cnuser02-evidence.txt"
