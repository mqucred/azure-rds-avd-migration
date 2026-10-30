<#
.SYNOPSIS
    Phase 14 - AD Retirement & Final Cloud-Native Validation
    DC-Off Test Matrix - VM-side checks (run on AVD session hosts)

.DESCRIPTION
    Run Part 1 on host-1 signed in as avduser01 (cloud-native, expect full pass).
    Part 2 is executed on host-0 / via the AVD client as avduser02 (hybrid control,
    expect failure - this is validated primarily via CLI, see phase14-cli-checklist.sh).
    Part 3 triggers the Sentinel/SOAR automation check.

.NOTES
    Project 6 - AVD/RDS Migration Lab - Central India
    Phase 14, 2026-10-19 / 2026-10-20
#>

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

# =====================================================================
# PART 1 — Test 1: avduser01 cloud-native identity (run on host-1)
# =====================================================================

Write-Section "PART 1 - Test 1: avduser01 Cloud-Native Identity Check"

Write-Host "`n--- Identity context ---" -ForegroundColor Yellow
hostname
whoami

Write-Host "`n--- dsregcmd /status ---" -ForegroundColor Yellow
Write-Host "Expect: AzureAdJoined=YES, DomainJoined=NO, OnPremTgt=NO, CloudTgt=YES" -ForegroundColor DarkGray
dsregcmd /status

Write-Host "`n--- klist (Kerberos tickets) ---" -ForegroundColor Yellow
Write-Host "Expect: only KERBEROS.MICROSOFTONLINE.COM tickets, no real on-prem KDC ticket" -ForegroundColor DarkGray
klist

Write-Host "`n--- DC unreachability proof ---" -ForegroundColor Yellow
Write-Host "Expect: all three fail (non-existent domain / unreachable / no DC found)" -ForegroundColor DarkGray
Write-Host ">> nslookup contoso.local"
nslookup contoso.local
Write-Host "`n>> ping vm-onprem-dc01"
ping vm-onprem-dc01
Write-Host "`n>> nltest /dsgetdc:contoso.local"
nltest /dsgetdc:contoso.local

Write-Host "`n--- FSLogix profile mount ---" -ForegroundColor Yellow
Write-Host "Expect: VHDLocations points at stavdfslogixcn01.file.core.windows.net, Enabled=1" -ForegroundColor DarkGray
Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles" -ErrorAction SilentlyContinue

# =====================================================================
# PART 2 — Test 2: avduser02 hybrid control (sign-in attempt, host-0)
# =====================================================================

Write-Section "PART 2 - Test 2: avduser02 Hybrid Control (run on host-0)"
Write-Host @"
Attempt sign-in through the Windows App / AVD client as avduser02.
Expected: failure. Primary evidence for this test is already captured via CLI:

  - Graph API confirms onPremisesSyncEnabled=true, onPremisesDistinguishedName
    and onPremisesImmutableId populated (hybrid identity confirmed)
  - Password reset attempt fails with Error Code 120013 (on-prem sync write-back
    failure) - this IS the test result; no working credential is required.

See phase14-cli-checklist.sh, Segment 5, for the exact commands.
"@ -ForegroundColor DarkGray

# =====================================================================
# PART 3 — Test 5: Sentinel/SOAR trigger (run on host-1 as avduser01)
# =====================================================================

Write-Section "PART 3 - Test 5: Sentinel/SOAR Trigger"
Write-Host @"
Attempt sign-in with a WRONG password 3x via the AVD client/feed as avduser01.
Then verify via CLI (phase14-cli-checklist.sh, Segment 7b):

  SecurityIncident
  | where TimeGenerated > ago(30m)
  | project IncidentNumber, Title, Status, Classification, CreatedTime, LastModifiedTime
  | order by CreatedTime desc

Expected: incident created, auto-classified FalsePositive, closed within seconds,
zero manual intervention, DC offline throughout.
"@ -ForegroundColor DarkGray

Write-Section "DONE"
Write-Host "Phase 14 VM-side validation complete." -ForegroundColor Green
Write-Host "Note: Test 4 (App Attach) intentionally skipped - documented known" -ForegroundColor DarkGray
Write-Host "limitation since Phase 12, no functional mount exists to validate." -ForegroundColor DarkGray
