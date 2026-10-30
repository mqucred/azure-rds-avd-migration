<#
.SYNOPSIS
    Phase 13 — Cloud-native identity sign-in fix + FSLogix profile recovery.
    Project 6 (Hybrid RDS -> AVD Cloud-Native Modernization).

.DESCRIPTION
    Captures the commands that actually diagnosed and fixed Phase 13's two
    real issues:
      1. AVD sign-in failure -> missing "Virtual Machine User Login" RBAC role
      2. FSLogix profile not attaching -> original data stranded on legacy
         AD-based storage account; recovery required deleting a corrupted
         container and re-populating a fresh one through a LIVE session.

    This is a reference/runbook script, not a one-shot automation — the
    variables at the top must be reviewed and the recovery section (Part 3)
    should be walked through deliberately, not run unattended, since it
    deletes a profile container.

.NOTES
    Environment: rg-avd-prod-centralindia-001 / hp-avd-prod-02 / vm-avd-host-1
    Run Part 1 and Part 2 from an elevated (admin) PowerShell session.
    Run the final verification block from the AFFECTED USER'S live session.
#>

# ============================================================
# VARIABLES — review before running
# ============================================================
$ResourceGroup      = "rg-avd-prod-centralindia-001"
$SubscriptionId     = "41a2b403-5b13-4a58-8cc0-c3ec75dba78a"
$NewStorageAccount  = "stavdfslogixcn01"
$NewShare           = "profiles-cn"
$OldStorageAccount  = "stavdfslogixprod012842"      # legacy, AD-based identity
$GroupObjectId      = "ba5d6dd4-4ec2-4f56-a6ad-661566eceecd"  # GRP-CN-AVD-USERS
$UserSid            = "S-1-12-1-639695800-1296507580-396824981-1392079666" # avduser01 cloud SID
$ProfileFolder      = "avduser01_$UserSid"


# ============================================================
# PART 1 — Sign-in fix: missing VM-scope RBAC role
# ============================================================
# Root cause: GRP-CN-AVD-USERS had "Desktop Virtualization User" on the
# app group, but NOT "Virtual Machine User Login" at VM/RG scope.
# Both are required independently for Entra-joined session host sign-in.

New-AzRoleAssignment `
    -ObjectId $GroupObjectId `
    -RoleDefinitionName "Virtual Machine User Login" `
    -Scope "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

# Verify:
Get-AzRoleAssignment `
    -Scope "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" |
    Where-Object { $_.ObjectId -eq $GroupObjectId }

# Confirmation test (run on the session host, as the affected user):
#   dsregcmd /status
#   Look for: AzureAdPrt : YES   and   CloudTgt : YES


# ============================================================
# PART 2 — Diagnose FSLogix attach failure (read-only checks)
# ============================================================

# 2a. Firewall check — use parentheses + property access, NOT the default
#     table view. The default Get-AzStorageAccountNetworkRuleSet table
#     TRUNCATES the IpRules array display as "[ip,...]" and will make a
#     fully-populated rule set look empty. This cost significant time
#     during Phase 13 diagnosis.
(Get-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroup -Name $NewStorageAccount).IpRules

# 2b. Confirm actual current egress IP (don't trust a stale captured value)
Invoke-RestMethod -Uri "https://api.ipify.org"

# 2c. Add the session host's egress IP permanently if missing
Add-AzStorageAccountNetworkRule -ResourceGroupName $ResourceGroup -Name $NewStorageAccount -IPAddressOrRange "<egress-ip>/32"

# 2d. Port + identity checks
Test-NetConnection -ComputerName "$NewStorageAccount.file.core.windows.net" -Port 445
Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $NewStorageAccount |
    Select-Object -ExpandProperty AzureFilesIdentityBasedAuth

# 2e. Check Entra sign-in logs for the storage account auth attempt at the
#     exact FSLogix log timestamp — Success here rules out the identity
#     layer entirely and points you at the profile container itself.
#     (Entra admin center -> Sign-in logs -> filter by user + time range)

# 2f. Pull the live FSLogix log for the real error
Get-ChildItem "C:\ProgramData\FSLogix\Logs\Profile\" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
# Then:
# Select-String -Path "<latest log>" -Pattern "VHD|Attach|Mount|ErrorCode|FindFile|LoadProfile" |
#     Select-Object LineNumber, Line


# ============================================================
# PART 3 — Recovery: locate old data, rebuild clean container
#          (run from an ELEVATED / admin session, e.g. azlabadmin)
# ============================================================

# 3a. Open both storage firewalls temporarily to investigate the legacy account
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroup -Name $NewStorageAccount -DefaultAction Allow
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroup -Name $OldStorageAccount -DefaultAction Allow

# 3b. Find the legacy share and the original VHDX
$ctxOld = (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $OldStorageAccount).Context
Get-AzStorageShare -Context $ctxOld

# Legacy account is AD-identity based (DirectoryServiceOptions: AD) — avduser01's
# cloud-only Kerberos ticket cannot authenticate to it. Use the storage key instead.
$oldKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $OldStorageAccount)[0].Value
net use Z: "\\$OldStorageAccount.file.core.windows.net\profiles" /user:"localhost\$OldStorageAccount" $oldKey

# 3c. Copy the original VHDX locally (adjust the old-SID folder name to match what you find)
New-Item -ItemType Directory -Path "C:\Temp" -Force
Copy-Item "Z:\<old-sid-folder>\Profile_avduser01.VHDX" -Destination "C:\Temp\Profile_avduser01_OLD.VHDX"

# 3d. Mount locally and confirm the real files are present (READ-ONLY inspection — do not write here)
Mount-DiskImage -ImagePath "C:\Temp\Profile_avduser01_OLD.VHDX"
Get-DiskImage -ImagePath "C:\Temp\Profile_avduser01_OLD.VHDX" | Get-Disk | Get-Partition | Get-Volume
# Note the assigned drive letter, then:
# Get-ChildItem "<letter>:\Profile\Desktop" -Force
# Get-ChildItem "<letter>:\Profile\Documents" -Force -Exclude "My Music","My Pictures","My Videos"

# 3e. Extract files to a local staging folder (file-level, NOT the VHDX container)
New-Item -ItemType Directory -Path "C:\Temp\RecoveredFiles\Desktop" -Force
New-Item -ItemType Directory -Path "C:\Temp\RecoveredFiles\Documents" -Force
Copy-Item "<letter>:\Profile\Desktop\*" -Destination "C:\Temp\RecoveredFiles\Desktop\" -Force
Copy-Item "<letter>:\Profile\Documents\*" -Destination "C:\Temp\RecoveredFiles\Documents\" -Force -Exclude "My Music","My Pictures","My Videos"

# 3f. Dismount — do not attempt to copy this VHDX container directly to the
#     new share and reuse it. A container-to-container copy was tried in
#     Phase 13 and failed a SHA-256 hash check (Get-FileHash) after transfer.
Dismount-DiskImage -ImagePath "C:\Temp\Profile_avduser01_OLD.VHDX"

# 3g. Delete the corrupted/empty container on the NEW share so FSLogix
#     provisions a genuinely fresh one at next sign-in
$newKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $NewStorageAccount)[0].Value
net use X: "\\$NewStorageAccount.file.core.windows.net\$NewShare" /user:"localhost\$NewStorageAccount" $newKey
Remove-Item "X:\$ProfileFolder\Profile_avduser01.VHDX" -Force -ErrorAction SilentlyContinue

# 3h. Stage the recovered files on the share so the live user session can reach them
New-Item -ItemType Directory -Path "X:\_recovery_staging" -Force
Copy-Item "C:\Temp\RecoveredFiles\Desktop\*" -Destination "X:\_recovery_staging\" -Force
Copy-Item "C:\Temp\RecoveredFiles\Documents\*" -Destination "X:\_recovery_staging\" -Force
net use X: /delete
net use Z: /delete


# ============================================================
# PART 4 — Re-inject files (RUN AS THE AFFECTED USER, LIVE SESSION ONLY)
#          Never mount/edit the VHDX offline to do this step — see README
#          for why that corrupts the container's registry hive validation.
# ============================================================
<#
    1. Sign out of avduser01's AVD session completely (not disconnect),
       sign back in. FSLogix will auto-provision a fresh container.

    2. From avduser01's own live PowerShell session, run:

    Copy-Item "\\stavdfslogixcn01.file.core.windows.net\profiles-cn\_recovery_staging\2842.txt" -Destination "C:\Users\avduser01\Desktop\" -Force
    Copy-Item "\\stavdfslogixcn01.file.core.windows.net\profiles-cn\_recovery_staging\flip flop change made.txt" -Destination "C:\Users\avduser01\Desktop\" -Force
    Copy-Item "\\stavdfslogixcn01.file.core.windows.net\profiles-cn\_recovery_staging\New Text Document.txt" -Destination "C:\Users\avduser01\Desktop\" -Force
    Copy-Item "\\stavdfslogixcn01.file.core.windows.net\profiles-cn\_recovery_staging\new file made.txt" -Destination "C:\Users\avduser01\Documents\" -Force

    3. Sign out COMPLETELY again, sign back in. This forces a real FSLogix
       save-and-reattach cycle, which is the only valid way to confirm the
       container and data are both genuinely intact.

    4. Verify:
    Get-ChildItem "C:\Users\avduser01\Desktop" -Force
    Get-ChildItem "C:\Users\avduser01\Documents" -Force

    5. Confirm clean FSLogix log (no ValidateRegistryImportFile / ErrorCode 13):
    Get-ChildItem "C:\ProgramData\FSLogix\Logs\Profile\" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    # Should show: "Attached vhd(x) successfully" then "LoadProfile successful."
#>


# ============================================================
# PART 5 — Closeout
# ============================================================
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroup -Name $NewStorageAccount -DefaultAction Deny
Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $ResourceGroup -Name $OldStorageAccount -DefaultAction Deny

Stop-AzVM -ResourceGroupName $ResourceGroup -Name "vm-onprem-dc01" -Force
Stop-AzVM -ResourceGroupName $ResourceGroup -Name "vm-onprem-rds01" -Force

# Remove 10.100.1.4 from spoke custom DNS via Portal or:
# Set-AzVirtualNetwork / Set-AzVirtualNetworkSubnetConfig as applicable to your VNet setup
