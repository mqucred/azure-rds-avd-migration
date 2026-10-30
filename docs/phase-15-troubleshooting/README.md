# Phase 15: Troubleshooting and open issues

**Status:** 30 issues documented

## Purpose

Real labs produce issues.

A vague "fixed it eventually" is worse than no entry.

---

### Issue 1: RD Web Access unreachable after RDS role install ("can't reach this page")

**Status:** Resolved. Root cause was two stacked problems, not one — a genuinely broken RDS deployment, and separately, a browser-specific TLS/rendering failure in Edge that persisted even after the deployment was fixed.

#### Summary

After installing the RD Gateway, Connection Broker, Session Host and Web Access roles on `vm-onprem-rds01` via the Server Manager Quick Start wizard, `https://vm-onprem-rds01 .contoso.local/RDWeb` failed to load in Edge with a generic "can't reach this page" error. The server rebooted more than once, unprompted, during the wizard's role install sequence. Investigation found the RDS deployment's broker database was left in a partially-registered state by the interrupted install: Windows Features showed roles as `Installed`, but the broker itself (`Get-RDServer`) either errored with "Connection Broker server is not available" or returned an empty server list, depending on which point in the corruption we were looking at. A ***clean role removal and reinstall using a single non-interactive command fixed the deployment***. After that fix, the URL *still* failed in Edge specifically, while `Invoke-WebRequest` from PowerShell and Internet Explorer both succeeded — the remaining failure was Edge, not the infrastructure.

#### Topology / context

| Item                 | Value                                                                                      |
|----------------------|----------------------------------------------------------------------------------------------|
| Phase affected       | Phase 1 (on-prem RDS baseline)                                                             |
| Resource(s) involved | `vm-onprem-rds01` (RD Gateway, Connection Broker, Session Host, Web Access, all on one VM) |
| Relevant IPs / names | `vm-onprem-rds01.contoso.local`, `10.100.1.5`; tested from `vm-onprem-dc01`, `10.100.1.4`  |

#### Symptom

**Browser (Edge)**, on a domain-joined VM inside the VNet, visiting the correct HTTPS URL:

```
https://vm-onprem-rds01.contoso.local/rdweb
"Hmmm… can't reach this page. It looks like the webpage at
https://vm-onprem-rds01.contoso.local/rdweb might be having issues, or it may have
moved permanently to a new web address."
```

#### What was checked, and what it showed

| \# | Layer                                                        | Check                                                                                                                                                                                                     | Result                                                                                                                                                                                                | Evidence                                                                                                                                                           |
|----|----------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | Windows Features                                             | `Get-WindowsFeature | Where-Object {$_.Name -like 'RDS-*'}`                                                                                                                                               | RDS-Connection-Broker, RDS-RD-Server, RDS-Web-Access showed `Installed`; RDS-Gateway showed `Available` (not installed) on first check                                                                | NA                                                                                                                                                                 |
| 2  | Deployment state                                             | `Get-RDServer -ConnectionBroker vm-onprem-rds01.contoso.local`                                                                                                                                            | Errored: "The RD Connection Broker server is not available."                                                                                                                                          | [evidence/phase15-rdweb-getrdserver-error.txt](../evidence/phase15-rdweb-getrdserver-error.txt) |
| 3  | Local IIS reachability                                       | `Test-NetConnection -ComputerName localhost -Port 443` (run ON the RDS VM)                                                                                                                                | `TcpTestSucceeded: True`                                                                                                                                                                              | NA                                                                                                                                                                 |
| 4  | Feature vs deployment mismatch                               | Installed RDS-Gateway feature with `Add-WindowsFeature`, then re-ran `Get-RDServer`                                                                                                                       | Feature showed `Installed`, but `Get-RDServer` still only listed `{RDS-RD-SERVER, RDS-CONNECTION-BROKER, RDS-WEB-ACCESS}` — Gateway absent from the *deployment* despite being an installed *feature* | contradiction was the key clue — two different data sources disagreeing                                                                                            |
| 5  | Attempted deployment registration                            | `Add-RDServer -Server ... -Role RDS-GATEWAY ...`                                                                                                                                                          | `Get-RDServer` afterward returned no error but no output either — broker now reachable but reporting zero registered servers                                                                          | NA                                                                                                                                                                 |
| 6  | Full role removal                                            | `Remove-WindowsFeature -Name RDS-Gateway,RDS-Web-Access,RDS-Connection-Broker,RDS-RD-Server -IncludeManagementTools -Restart`                                                                             | First attempt: partial removal only — Gateway removed, other three roles still showed `Installed` after the restart                                                                                   | NA                                                                                                                                                                 |
| 7  | Clean reinstall                                              | `Install-WindowsFeature -Name RDS-Connection-Broker,RDS-Web-Access,RDS-RD-Server -IncludeManagementTools -Restart` (single command, one restart, not the GUI wizard)                                      | Roles installed cleanly this time                                                                                                                                                                     | NA                                                                                                                                                                 |
| 8  | Deployment creation                                          | `New-RDSessionDeployment -ConnectionBroker ... -WebAccessServer ... -SessionHost ...`                                                                                                                     | Completed (progress bar observed), then `Get-RDServer` returned all three roles correctly registered                                                                                                  | see decisive observation below                                                                                                                                     |
| 9  | Local page render (on the RDS VM)                            | `Invoke-WebRequest -Uri "https://localhost/RDWeb" -UseBasicParsing` (with a `TrustAllCertsPolicy` override for the self-signed cert, since `-SkipCertificateCheck` isn't valid in Windows PowerShell 5.1) | `200 OK`, full RDWeb XML payload returned, `WorkSpaceID` correctly set                                                                                                                                | evidence/phase15-rdweb-localhost-200.txt       |
| 10 | Remote page render (from the DC, over the real network path) | Same `Invoke-WebRequest`, but from `vm-onprem-dc01` against the full FQDN                                                                                                                                 | `200 OK`, identical payload                                                                                                                                                                           | evidence/phase15-rdweb-localhost-200.txt    |
| 11 | Network path check                                           | `Test-NetConnection -ComputerName vm-onprem-rds01.contoso.local -Port 443` from the DC                                                                                                                    | `TcpTestSucceeded: True`, resolved to `10.100.1.5` correctly                                                                                                                                          | —                                                                                                                                                                  |
| 12 | Browser isolation                                            | Same URL, same VM, same session — tried Internet Explorer instead of Edge                                                                                                                                 | Loaded successfully                                                                                                                                                                                   | images/phase-15/Screenshot (173).png                                     |

#### The decisive observation

Two `Invoke-WebRequest` calls, both returning `200 OK` with the identical RDWeb XML payload — one from `localhost` on the RDS VM itself, one from the DC against the full FQDN over the real network path — proved conclusively that IIS, the RDS deployment, DNS, routing, and the NSG were all correctly configured. The only thing that still failed after that point was Edge, on the same machine, hitting the same URL, with no certificate warning and no specific error — just a generic "can't reach this page." Internet Explorer, run immediately after on the same session, loaded the page without issue. This isolates the remaining failure to Edge's own TLS/rendering behavior toward a self-signed certificate on this Windows Server build, not to anything in the RDS/IIS/network stack.

#### Things that were tried and did not help

- Disabling the Windows Firewall entirely on both the DC and RDS VM.
- Disabling IE Enhanced Security Configuration.
- Clearing Edge's cache and cookies, flushing DNS (`ipconfig /flushdns`).
- Checking Edge's proxy settings (`HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings`) — not the cause in this case, but worth checking early next time since a stray `ProxyEnable=1` would produce this exact symptom and is faster to rule out than everything above.

#### Limitations of the evidence

- The very first `Get-WindowsFeature` check after role removal returned genuinely blank output (confirmed clean state) — but a later mid-conversation `Get-WindowsFeature` check was initially misread as still showing installed roles, when it was actually output from *before* the removal step. Always note the exact command sequence and timestamp when copying terminal output for a report; interleaved command history is easy to misattribute.
- No packet capture or IIS log excerpt was taken for the Edge-specific failure — the isolation rests on the PowerShell-vs-IE comparison alone. A `Get-WebBinding` / `Get-ChildItem IIS:\Sites` check was run at one point and returned `Get-Website` as blank while `Get-ChildItem IIS:\Sites` correctly showed the Default Web Site — worth noting that `Get-Website` was unreliable in this session and `Get-ChildItem IIS:\Sites` was the trustworthy source for IIS site state.
- The exact reason Edge fails (TLS cipher negotiation, a Server-SKU-specific Edge policy, or something else) was never root-caused — only worked around by using a different browser.

#### What I would try next

1. Capture the Edge failure with F12 DevTools open (Network + Console tabs) to see whether Edge logs a specific TLS or certificate error before giving up, rather than the generic page.
2. Check `edge://net-internals/#events` during a reproduction for a more detailed failure reason than the user-facing error page shows.
3. Test whether installing a properly-trusted certificate (rather than the RDS self-signed default) resolves it in Edge, which would confirm a cert-trust cause rather than something else Edge-specific.

#### Workaround

Use Internet Explorer (or any non-Edge browser) to access RD Web Access on this lab's Windows Server VMs. This fully meets the goal of reaching RDWeb for testing purposes, but does not explain or fix the underlying Edge behavior, and should not be assumed to generalize to a production RDS deployment with a properly-trusted certificate.

#### Reference commands

```
# Check deployment state
Get-RDServer -ConnectionBroker vm-onprem-rds01.contoso.local

# Full clean removal (single command, let the restart complete uninterrupted)
Remove-WindowsFeature -Name RDS-Gateway, RDS-Web-Access, RDS-Connection-Broker, RDS-RD-Server -IncludeManagementTools -Restart

# Clean reinstall (single command, not the GUI wizard, one restart)
Install-WindowsFeature -Name RDS-Connection-Broker, RDS-Web-Access, RDS-RD-Server, RDS-Gateway -IncludeManagementTools -Restart

# Create the actual deployment (this step is separate from installing features,
# and is the step that was missing originally)
New-RDSessionDeployment -ConnectionBroker "vm-onprem-rds01.contoso.local" -WebAccessServer "vm-onprem-rds01.contoso.local" -SessionHost "vm-onprem-rds01.contoso.local"

# Register Gateway into the deployment explicitly if it wasn't included above
Add-RDServer -Server "vm-onprem-rds01.contoso.local" -Role RDS-GATEWAY -ConnectionBroker "vm-onprem-rds01.contoso.local" -GatewayExternalFqdn "vm-onprem-rds01.contoso.local"

# Test the page directly, bypassing the browser, to isolate server vs. client issues
# (Windows PowerShell 5.1 has no -SkipCertificateCheck flag, unlike PS7+ — this is
# the 5.1-compatible way to trust a self-signed cert for one request)
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
Invoke-WebRequest -Uri "https://vm-onprem-rds01.contoso.local/RDWeb" -UseBasicParsing
```

---

### Issue 2: `Install-ADDSForest -InstallDns` rejected — read as a syntax error, was actually a real conflict

**Status:** Resolved. Root cause was operator error (DNS already present from an earlier attempt), not a bug in the command. Documented mainly for the process lesson, not the fix.

#### Summary

Running `Install-ADDSForest -DomainName "contoso.local" -InstallDns -Force` failed with `The specified argument 'InstallDns' was not recognized`, alongside a separate `SafeModeAdministratorPassword` mismatch from the interactive prompt. The password mismatch was a simple retyping error. The `InstallDns` rejection was initially treated as a parameter-parsing bug and investigated with `Get-Command`, explicit boolean switch syntax, and a restructured command — none of which was the actual issue. The real cause: DNS was already present on the box from an earlier promotion attempt, and the prerequisite check correctly refused to install DNS again as part of forest creation. The error message was accurate; the response to it initially wasn't.

#### Topology / context

| Item                 | Value                             |
|----------------------|------------------------------------|
| Phase affected       | Phase 1 (on-prem AD DS promotion) |
| Resource(s) involved | `vm-onprem-dc01`                  |
| Relevant IPs / names | `contoso.local`                   |

#### Symptom

```
PS C:\Users\azlabadmin> Install-ADDSForest -DomainName "contoso.local" -InstallDns -Force
Input and confirm input for SafeModeAdministratorPassword do not match. Please try again.
Install-ADDSForest : Verification of prerequisites for Domain Controller promotion failed. The specified
argument 'InstallDNS' was not recognized.
```

#### What was checked, and what it showed

| \# | Layer                 | Check                                                                                                                                        | Result                                                                                                                                                                        | Evidence                                            |
|----|------------------------|------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------|
| 1  | Cmdlet availability   | `Get-Command Install-ADDSForest | Select Name, ModuleName, Version`                                                                          | Suggested as a next step, to rule out a missing/wrong `ADDSDeployment` module                                                                                                 | not run — issue was resolved before this was needed |
| 2  | Command restructuring | Rebuilt the command with `-SafeModeAdministratorPassword` pre-set as a variable and `-InstallDns:$true -Force:$true` explicit boolean syntax | Proposed as a fix for a suspected parser issue                                                                                                                                | this was the wrong diagnosis, see below             |
| 3  | Actual cause          | Re-read of the error text and the box's real state                                                                                           | DNS was already installed/configured from an earlier promotion attempt on this VM; `Install-ADDSForest -InstallDns` correctly refused to reconfigure DNS that already existed | "I being fool to install dns upon dns"              |

#### The decisive observation

The error message itself — `argument 'InstallDNS' was not recognized` — was misread as a PowerShell parameter-binding problem. It wasn't. `Install-ADDSForest`'s prerequisite checker was rejecting the *combination* of "install DNS as part of this forest" against a box that already had DNS in some state from a prior attempt. The fix wasn't a different command shape; it was recognizing that `-InstallDns` didn't apply a second time. No amount of restructuring the command syntax would have fixed a correctly-functioning rejection.

#### Things that were tried and did not help

- Checking `Get-Command Install-ADDSForest` for module/version mismatch — not the cause.
- Rewriting the command with pre-set password variable and explicit `:$true` boolean switches — syntactically cleaner, but irrelevant to this specific error, since the original bare-switch syntax was never actually broken.

#### Limitations of the evidence

- The exact prior state of DNS on the box before this attempt (what earlier step left it configured) wasn't captured — only inferred after the fact from the user's own diagnosis. If this recurs, check `Get-WindowsFeature DNS` and `Get-DnsServerZone` *before* attempting `Install-ADDSForest` again, to have the actual prior state on record rather than reconstructing it afterward.

#### What I would try next

1. Before any future `Install-ADDSForest` attempt on a VM that's been touched before, run `Get-WindowsFeature DNS` and, if present, `Get-DnsServerZone` first, to know in advance whether `-InstallDns` is appropriate or should be omitted.
2. If DNS is already present and correctly configured, omit `-InstallDns` entirely from the promotion command rather than troubleshooting why it's "rejected."

#### Workaround

None needed — omitting `-InstallDns` on a retry (once DNS already exists) is the correct behavior, not a workaround.

#### Reference commands

```
# Check before assuming -InstallDns is needed on a VM that's been previously touched
Get-WindowsFeature DNS
Get-DnsServerZone

# The corrected mental model, not a different syntax:
# -InstallDns means "also configure DNS as part of this promotion" --
# omit it if DNS is already present and correctly set up.
Install-ADDSForest -DomainName "contoso.local" -Force
# (add -InstallDns only on a genuinely first attempt, on a clean box)
```

#### Process lesson (general, not just this issue)

When an error message names a specific, plausible real-world conflict (a resource that already exists, a role already installed, a state that's already set), investigate that literal claim first before restructuring the command's syntax. A restructured command can accidentally "fix" a symptom by changing what's being asked, without ever confirming what was actually wrong — and can waste time solving a problem that didn't exist while missing the one that did.

---

### Issue 3: Phase 4 — stale AD object conflict, missing share-quota parameter, and an admin group name mismatch

**Status:** Resolved via full teardown and clean rebuild. Three distinct, unrelated problems stacked in this one phase — documented separately below since they had different causes and different fixes, and conflating them during troubleshooting would have been easy to do.

#### Summary

Phase 4 (Azure Files, AD Kerberos join, RBAC, NTFS) failed on first attempt and needed a full teardown and rebuild. Three separate issues were involved: (1) an earlier, incomplete `Join-AzStorageAccountForAuth` run left a stale AD computer object that blocked a clean retry; (2) `New-AzStorageShare` has no quota parameter at all on the installed Az.Storage module version — not a `GiB`/`GB` naming difference, confirmed directly via `Get-Command -Syntax`, after two wrong guesses;

#### Topology / context

| Item                 | Value                                                                                                      |
|----------------------|----------------------------------------------------------------------------------------------------------- |
| Phase affected       | Phase 4 (Azure Files, Kerberos, RBAC, NTFS); symptom of issue 3 surfaced in Phase 5                        |
| Resource(s) involved | `stavdfslogixprod012842` storage account, its AD computer object in `OU=AVD_Hosts`, `ADMINS ONLY` AD group |
| Relevant IPs / names | `vm-onprem-dc01` (where all AD-join and NTFS steps were run)                                               |

#### Symptom

**Issue 3a (stale AD object):**

```
New-ADAccountForStorageAccount : An AD object
'CN=stavdfslogixprod012842,OU=AVD_Hosts,DC=contoso,DC=local' with a Service
Principal Name of cifs/stavdfslogixprod012842.file.core.windows.net already
exists within AD. This might happen because you are rejoining a new storage
account that shares names with an existing storage account, or if the domain
join operation for a storage account failed in an incomplete state.
```

**Issue 3b (quota parameter):**

```
New-AzStorageShare : A parameter cannot be found that matches parameter name 'QuotaGiB'.
[retried with QuotaGB]
New-AzStorageShare : A parameter cannot be found that matches parameter name 'QuotaGB'.
```

#### What was checked, and what it showed

| \# | Layer                            | Check                                                                          | Result                                                                                                                                                                       | Evidence                                                                                                                                                                           |
|----|------------------------------------|----------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1  | AD object state                  | Re-ran `Join-AzStorageAccountForAuth` after the SPN-conflict error             | Confirmed the error named the exact cause: "domain join operation ... failed in an incomplete state"                                                                         | see Symptom above                                                                                                                                                                  |
| 2  | Fix attempt                      | Added `-OverwriteExistingADObject` to the join command                         | Succeeded — `$sa.AzureFilesIdentityBasedAuth` then showed `DirectoryServiceOptions: AD` with `ActiveDirectoryProperties` populated                                           | evidence/phase4-ad-join-verification.txt                                                                                     |
| 3  | Share creation, attempt 1        | `New-AzStorageShare ... -QuotaGiB <int>`                                       | Failed, parameter not found                                                                                                                                                  | evidence/phase4-quotagb-portal-fallback-note.txt                                                                             |
| 4  | Share creation, attempt 2        | `New-AzStorageShare ... -QuotaGB <int>`                                        | Failed again, parameter not found — same error class, different guessed name                                                                                                | same                                                                                                                                                                               |
| 5  | Root cause check                 | `Get-Command New-AzStorageShare -Syntax`                                       | Full parameter list returned has **no quota parameter of any name** on this module version                                                                                   | same                                                                                                                                                                               |
| 6  | Correct pattern confirmed        | `Get-Command Set-AzStorageShareQuota -Syntax`                                  | Confirmed to exist, with `-ShareName`, `-Quota`, `-Context`                                                                                                                  | same                                                                                                                                                                               |
| 7  | Workaround used                  | Created both shares via Azure Portal instead, quota set in the creation dialog | Succeeded                                                                                                                                                                    | images/phase-4/01-phase4-storage-account-shares.png |
| 8  | Confirming the mismatch's effect | Reviewed Phase 5's earlier stall                                               | Consistent with a name-based AD lookup for `GRP-AVD-ADMINS` failing silently, since no group by that literal name exists — object-ID-based RBAC commands were never affected | NA                                                                                                                                                                                 |

#### The decisive observation

For Issue 3b specifically: `Get-Command New-AzStorageShare -Syntax` printed the complete, authoritative parameter list for the cmdlet as actually installed — `-Name`, `-Protocol`, `-EnableSnapshotVirtualDirectoryAccess`, `-Context`, `-ServerTimeoutPerRequest`, `-ClientTimeoutPerRequest`, `-DefaultProfile`, `-ConcurrentTaskCount`, `-AcquirePolicyToken`, `-ChangeReference`. No quota parameter of any name appears. Two guesses (`-QuotaGiB`, then `-QuotaGB`) were tried before checking this directly — both were guesses at a naming convention, when the real answer was that quota isn't a parameter on this cmdlet at all on this module version.

For Issue 3a: the error text itself named the cause plainly ("failed in an incomplete state") — the fix was in the same error message, as the `-OverwriteExistingADObject` suggestion. This is the same category of lesson as Issue 2: read what the error claims before assuming it needs a different approach.

#### Things that were tried and did not help

- Guessing a second quota-parameter name (`-QuotaGB`) after the first guess (`-QuotaGiB`) failed, instead of checking `Get-Command -Syntax` after the first failure.
- Treating the stale-AD-object error as something to route around with bare `-Force` rather than the specific flag the error message itself named.

#### Limitations of the evidence

- The exact cause of the original incomplete join (what interrupted it, whether it was a prior session's attempt or something else) was not captured — only its symptom (the stale AD object) and its fix.
- `Set-AzStorageShareQuota` was confirmed to exist via `Get-Command -Syntax` but was not actually exercised in this run, since the portal fallback was used instead for time. A future phase that creates a share should use and verify the two-step pattern (`New-AzStorageShare` then `Set-AzStorageShareQuota`) directly to confirm it genuinely works end-to-end, not just that both cmdlets exist.
- Share quota could not be verified from `vm-onprem-dc01` after the firewall lockdown step (expected — the DC sits outside `snet-avd-storage`), so final quota values were not independently re-confirmed via PowerShell, only via the portal's own display at creation time.

#### What I would try next

1. On a future phase that creates a share (Phase 8 is a candidate), use the `New-AzStorageShare` + `Set-AzStorageShareQuota` two-step pattern for real, to confirm it works rather than relying on `Get-Command -Syntax` alone as proof.
2. Standardize on checking `Get-Command <cmdlet> -Syntax` before using any quota/size/unit-related parameter on an Az.* cmdlet, given Microsoft's inconsistent `GiB`/`GB`/`TB` naming across different cmdlets in the same module family — this would have saved two failed attempts here.

#### Workaround

Both file shares were created via the Azure Portal, with quota set directly in the share-creation dialog. This fully resolves the immediate need and is a legitimate, documented fallback — not a lesser solution — given that the scripted cmdlet genuinely lacks the needed parameter on this module version.

#### Reference commands

```
# Diagnose a stale AD object conflict during storage account AD join
Join-AzStorageAccountForAuth `
    -ResourceGroupName $SpokeRg `
    -StorageAccountName $StorageAccountName `
    -DomainAccountType "ComputerAccount" `
    -OrganizationalUnitDistinguishedName $OuDistinguishedName `
    -OverwriteExistingADObject

# Before guessing a parameter name on any Az.* cmdlet, check the real syntax first
Get-Command New-AzStorageShare -Syntax
Get-Command Set-AzStorageShareQuota -Syntax

# Correct two-step share creation when quota isn't a creation-time parameter
New-AzStorageShare -Name $ProfilesShareName -Context $ctx
Set-AzStorageShareQuota -ShareName $ProfilesShareName -Quota $ProfilesQuotaGB -Context $ctx

# Confirm an AD group's real display name before assuming it matches a script variable
Get-ADGroup -Filter "ObjectGUID -eq '8f79b6a8-24f4-48e0-874d-77dfcfcf7177'" | Select-Object Name, SamAccountName
```

---

### Issue 4: Session host stuck — portal showed "Running," host pool showed "Shutdown," unresponsive to deletion

**Status:** Resolved via full deletion and clean redeploy. Root cause not fully determined — documented ***honestly as unresolved at the diagnostic level, resolved at the operational level***.

#### Summary

After a working sign-in the previous night, `vm-avd-host-0` was found the next morning showing `Status: Shutdown` / `Unavailable` in the AVD host pool, while the Azure portal's own VM Overview blade showed it as "Running." Attempts to connect via the AVD client failed with "no available resources." The VM did not respond cleanly to `Stop-AzVM`, `Remove-AzVM`, or `az vm delete` without `--force-deletion`. Azure resource provider registration was checked and confirmed healthy, ruling that out as a cause. Given the contradictory status and unresponsiveness, the decision was made to delete the entire AVD layer (host pool, workspace, app group, VM, NIC, disk, public IP, and an auto-created boot-diagnostics storage account) and redeploy clean, rather than continue diagnosing a VM already in a self-contradictory state.

#### Topology / context

| Item                 | Value                                                                  |
|----------------------|--------------------------------------------------------------------------|
| Phase affected       | Phase 5                                                                |
| Resource(s) involved | `vm-avd-host-0`, `hp-avd-prod-01`, their supporting NIC/disk/public IP |
| Relevant IPs / names | `vm-avd-host-0.contoso.local`                                          |

#### Symptom

```
We couldn't connect because there are currently no available resources. Try again
later or if this keeps happening ask your admin or tech support for help.
```

Host pool query:

```
Get-AzWvdSessionHost ... | Select-Object Name, Status
Name: vm-avd-host-0   Status: Shutdown
```

Portal VM Overview: **Running**.

#### What was checked, and what it showed

| \# | Layer                          | Check                                                                                              | Result                                                                                                            | Evidence                                                                                                                                                                                                                                                                                                |
|----|---------------------------------|------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | Host pool status               | `Get-AzWvdSessionHost`                                                                             | `Shutdown`, later `Unavailable` / `NeedsAssistance`                                                               | NA                                                                                                                                                                                                                                                                                                      |
| 2  | VM power state                 | Azure portal VM Overview                                                                           | "Running" — directly contradicting #1                                                                             | NA                                                                                                                                                                                                                                                                                                      |
| 3  | AVD agent services             | `Get-Service RDAgentBootLoader, RdAgent` (planned check)                                           | Not completed before escalating to deletion — session ran out of productive diagnostic time                       | NA                                                                                                                                                                                                                                                                                                      |
| 4  | Resource provider registration | `Get-AzResourceProvider -ProviderNamespace Microsoft.Compute` (and Network, DesktopVirtualization) | All showed `Registered` — ruled out as a cause                                                                    | NA                                                                                                                                                                                                                                                                                                      |
| 5  | Deletion attempts              | `Stop-AzVM`, `Remove-AzVM`, portal Delete                                                          | All hung or failed to complete in reasonable time                                                                 | NA                                                                                                                                                                                                                                                                                                      |
| 6  | Forced deletion                | `az vm delete --force-deletion yes`                                                                | Eventually succeeded (exact point it unstuck was not isolated)                                                    | NA                                                                                                                                                                                                                                                                                                      |
| 7  | Full redeploy                  | Host pool, workspace, app group, session host, all rebuilt fresh                                   | Succeeded; session host reached `Available`; confirmed sign-in and FSLogix container creation for both test users | images/phase-5/02-phase5-session-host-available.png, images/phase-5/05-phase5-vhdx-created-usernamefirst.png |

#### The decisive observation

There isn't one, honestly — this is the main limitation of this writeup (see below). The portal-vs-host-pool status contradiction (#1 vs #2) is real and reproducible as a *symptom*, but no single piece of evidence pinpointed *why* the AVD agent stopped reporting correctly. The practical decisive factor was pragmatic, not diagnostic: after resource providers were confirmed healthy (#4) and deletion commands kept hanging (#5), continuing to diagnose a VM that wouldn't even delete cleanly was judged to cost more time than a clean rebuild, especially against a same-day deadline.

#### Things that were tried and did not help

- Checking resource provider registration (correctly ruled out, but didn't explain the actual fault).
- Plain `Stop-AzVM -Force` and `Remove-AzVM -Force` — both hung.
- Waiting — the stuck state did not self-resolve over the time it was observed.

#### Limitations of the evidence

- **Root cause genuinely unknown.** `Get-Service RDAgentBootLoader, RdAgent` (to check whether the AVD agent services themselves had stopped) was identified as the next diagnostic step but never actually run before the decision was made to delete and redeploy. This means Issue 4 and Issue 5 (Geneva/outbound internet) may or may not be the same underlying problem — plausible, not confirmed. If this recurs, run the service check first, before escalating to deletion.
- No Windows Event Viewer logs were pulled from the stuck VM before it was deleted — that evidence is gone and can't be reconstructed.
- `--force-deletion yes` eventually worked, but exactly how long the earlier plain commands were hung before being abandoned wasn't precisely timed.

#### What I would try next

1. If this recurs: check `Get-Service RDAgentBootLoader, RdAgent` on the session host *before* attempting any deletion — this is the one diagnostic step that was identified but not completed here.
2. Check Windows Event Viewer (Application and System logs) on a stuck host before deleting it, specifically for AVD agent or Geneva monitoring agent errors.
3. If the agent services are confirmed stopped, try `Restart-Service` before escalating to VM-level deletion — a much cheaper fix if it works.

#### Workaround

Full deletion of the AVD-layer resources and a clean redeploy. Phase 4's underlying storage/AD/RBAC work was untouched and did not need to be redone — only the AVD-layer resources (host pool, workspace, app group, VM and its NIC/disk/IP) were affected.

#### Reference commands

```
# Check contradictory status
Get-AzWvdSessionHost -ResourceGroupName $SpokeRg -HostPoolName $HostPoolName | Select-Object Name, Status
Get-AzVM -ResourceGroupName $SpokeRg -Name $HostVmName -Status | Select-Object Name, PowerState

# Rule out resource provider registration as a cause
Get-AzResourceProvider -ProviderNamespace "Microsoft.Compute" | Select-Object ProviderNamespace, RegistrationState
Get-AzResourceProvider -ProviderNamespace "Microsoft.DesktopVirtualization" | Select-Object ProviderNamespace, RegistrationState

# Forced deletion when plain Remove-AzVM hangs
az vm delete --resource-group $SpokeRg --name $HostVmName --yes --force-deletion yes
```

---

### Issue 5: AVD agent "Needs Assistance" / Geneva error — no NAT Gateway means no ongoing outbound internet, not just setup-time

**Status:** Resolved (workaround in use — temporary public IP kept attached permanently, pending a deliberate future NAT Gateway deployment).

#### Summary

After the Phase 5 redeploy succeeded and the temporary public IP was removed (per the original plan — "remove it once Available is confirmed"), the session host's status changed to `Running` (VM-level) / `Needs Assistance` (AVD agent level), with a Geneva monitoring-agent error visible in the host's JSON status detail. Reattaching the public IP resolved it. This means the project's original assumption — that session hosts only need outbound internet during one-time setup (agent/FSLogix installer downloads) — was wrong. The AVD agent needs **ongoing** outbound access for its own health/telemetry reporting, not just a one-time install step.

#### Topology / context

| Item                 | Value                                  |
|----------------------|------------------------------------------|
| Phase affected       | Phase 5                                |
| Resource(s) involved | `vm-avd-host-0`, `pip-avd-host-0-temp` |

#### Symptom

Host status: `Running` (VM) / `Needs Assistance` (AVD agent), with a Geneva-related error in the status JSON detail, appearing specifically after the temporary public IP was removed.

#### What was checked, and what it showed

| \# | Layer              | Check                                             | Result                                                             | Evidence |
|----|----------------------|------------------------------------------------------|-----------------------------------------------------------------------|------------|
| 1  | Public IP presence | `Get-AzPublicIpAddress -Name pip-avd-host-0-temp` | Confirmed removed (per the original "remove after Available" plan) | NA       |
| 2  | Fix                | Reattached the public IP to the NIC               | Status returned to `Available`                                     | NA       |

#### The decisive observation

The timing correlation is the evidence here: status changed from `Available` to `Needs Assistance` with a Geneva error at the same point the public IP was removed, and reattaching it resolved the status. This is a timing correlation, not an isolated proof (no packet capture confirming exactly what the agent was trying and failing to reach) — but combined with the project's known lack of a NAT Gateway, it's a sufficient and consistent explanation.

#### Things that were tried and did not help

N/A — the fix worked on the first reattachment attempt.

#### Limitations of the evidence

- The specific Microsoft endpoint(s) the Geneva agent needs to reach were not identified — only that *some* outbound path is required continuously, not just at setup. A future, more precise fix (e.g., specific outbound NSG/firewall rules to exact Microsoft endpoints, rather than full open outbound via a public IP) would need that endpoint list, which is in Microsoft's AVD networking documentation and should be checked before finalizing a NAT Gateway or firewall-based design.

#### What I would try next

1. Look up Microsoft's documented required outbound endpoints for AVD session hosts (there's a published list) and confirm the NAT Gateway or firewall design, when built, explicitly allows those rather than assuming open outbound is required.
2. Deploy a NAT Gateway as a deliberate, separate exercise — not under deadline pressure — and update the architecture diagram to reflect it as a permanent component, replacing the temporary public IP.

#### Workaround

The temporary public IP (`pip-avd-host-0-temp`) is being kept attached permanently for now, rather than removed, pending a deliberate NAT Gateway deployment later. This is a conscious, cost-aware decision: a Standard public IP's hourly cost is a small fraction of a NAT Gateway's flat hourly rate, and deploying new, untested infrastructure (NAT Gateway) under a same-day deadline was judged higher-risk than continuing with a known-working temporary measure. NAT Gateway remains the architecturally preferable, more zero-trust-aligned long-term fix (no inbound surface, centralized egress) and is planned as a separate, deliberate addition to the architecture diagram.

#### Reference commands

```
# Check if the temp public IP still exists
Get-AzPublicIpAddress -ResourceGroupName $SpokeRg -Name "pip-avd-host-0-temp" -ErrorAction SilentlyContinue

# Reattach if removed
$pip = New-AzPublicIpAddress -ResourceGroupName $SpokeRg -Name "pip-avd-host-0-temp" -Location $Location -AllocationMethod Static -Sku Standard
$nic = Get-AzNetworkInterface -ResourceGroupName $SpokeRg -Name "$HostVmName-nic"
$nic.IpConfigurations[0].PublicIpAddress = $pip
Set-AzNetworkInterface -NetworkInterface $nic
```

---

### Issue 6: Applying FlipFlopProfileDirectoryName orphaned existing FSLogix containers

**Status:** Resolved (expected behavior, confirmed against Microsoft's own documentation before acting).

#### Summary

After discovering FSLogix had been running on default settings (producing `.vhd` files in `<SID>_<username>` naming, rather than Microsoft's documented "Standard" tier), the full Standard registry configuration was applied, including `FlipFlopProfileDirectoryName=1` and `VolumeType=VHDX`. This caused FSLogix to no longer recognize the existing containers for `avduser01`, `avduser02`, and `azlabadmin` as current — it created new, separate, empty containers under the flipped `<username>_<SID>` naming instead, alongside the old ones. This matches a warning stated directly in Microsoft's own documentation.

#### Topology / context

| Item                 | Value                                        |
|----------------------|-----------------------------------------------|
| Phase affected       | Phase 5                                      |
| Resource(s) involved | `profiles` share on `stavdfslogixprod012842` |

#### Symptom

Portal file share listing showed duplicate containers per user — e.g. both `S-1-5-21-..._avduser01` (old) and, after the config change and a fresh sign-in, a new `avduser01_S-1-5-21-...` folder.

#### What was checked, and what it showed

| \# | Layer                      | Check                                                                                                                                                                                 | Result                                                                                                                                 | Evidence |
|----|------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|------------|
| 1  | Microsoft's own guidance   | Fetched https://learn.microsoft.com/en-us/fslogix/concepts-configuration-examples directly before acting | Explicit warning: "Be careful when changing this setting in an existing FSLogix environment as it can cause users to get new profiles" | NA       |
| 2  | Old containers             | Attempted deletion via `Remove-AzStorageDirectory`                                                                                                                                    | Failed initially — non-empty directory error; required deleting the inner `.vhd` file first, then the folder                           | NA       |
| 3  | One container (azlabadmin) | Deletion attempt                                                                                                                                                                      | Failed with an SMB lock error — likely a lingering mount/session from earlier `frx`/manual-copy troubleshooting                        | NA       |

#### The decisive observation

Checking Microsoft's own documentation *before* applying the change (rather than after hitting a symptom) meant the duplicate-container behavior was expected, not mysterious, when it appeared — this is the one issue in this project where the "decisive observation" was preventive rather than diagnostic.

#### Things that were tried and did not help

N/A — behavior matched documentation; no incorrect fix was attempted here.

#### Limitations of the evidence

- The exact cause of `azlabadmin`'s container lock (which process held it) was not identified — the deletion was abandoned as not worth the time, given `azlabadmin` is an incidental account, not a real test user.

#### What I would try next

If this container needs cleaning up later: check `Get-DiskImage` and `net use` on every machine that touched this profile path during troubleshooting (`vm-avd-host-0`, `vm-onprem-dc01`) for a lingering mount before retrying deletion.

#### Workaround

Old SID-first containers for `avduser01` and `avduser02` were deleted after confirming the real filenames inside each folder. `azlabadmin`'s old container was left in place as a known, harmless leftover — it doesn't interfere with the new containers, which live under entirely different folder names.

#### Reference commands

```
# Delete an old container: list real contents first, don't assume the filename
$ctx = (Get-AzStorageAccount -ResourceGroupName $SpokeRg -Name $StorageAccountName).Context
Get-AzStorageFile -ShareName "profiles" -Path "<old-folder-name>" -Context $ctx
Remove-AzStorageFile -ShareName "profiles" -Path "<old-folder-name>/<real-filename>" -Context $ctx
Remove-AzStorageDirectory -ShareName "profiles" -Path "<old-folder-name>" -Context $ctx
```

---

### Issue 7: "Temporary profile" warning misdiagnosed by a third-party AI tool — real cause was corrupted VHDX containers, not an AD profile path setting

**Status:** Resolved. Documented in detail because the misdiagnosis itself, and how it was caught, is a genuinely useful lesson.

#### Summary

After the FlipFlop reconfiguration (Issue 6), both `avduser01` and `avduser02` hit a "We can't sign in to your account" error on sign-in, and the FSLogix log confirmed a `WARN: 80090024` — the user was being logged in with a Windows temporary profile. A plausible-sounding explanation was offered by a different AI tool (Gemini), claiming that the on-prem AD user object's legacy roaming-profile `ProfilePath` attribute (set back in Phase 1, pointing at `\\vm-onprem-dc01\legacy-profiles\%username%`) was forcing Windows toward a roaming-profile code path that FSLogix couldn't satisfy, causing the temp-profile fallback. This explanation was **checked directly against the FSLogix log rather than accepted on its plausibility**, and found to be incorrect: the log showed FSLogix correctly attaching the real FSLogix VHDX (`VHDRootFilePath` pointing at the actual share path, `LogonStage=5` clean completion) — not falling back to a local profile as the alternative theory claimed. The actual cause, found by examining the Azure Portal's file share listing directly, was a set of **corrupted VHDX containers** — visible as files literally named `CORRUPT_<guid>_Profile_avduser01.VHDX` — left over from the earlier stuck-VM incident (Issue 4). Deleting the corrupted files let FSLogix create fresh, working containers on the next sign-in.

#### Topology / context

| Item                 | Value                             |
|----------------------|------------------------------------|
| Phase affected       | Phase 5                           |
| Resource(s) involved | `profiles` share, `vm-avd-host-0` |

#### Symptom

```
We can't sign in to your account. This problem can often be fixed by signing out
of your account and then signing back in. If you don't sign out now, any files
you create or changes you make will be lost.
```

FSLogix log, at the time:

```
[WARN: 80090024]  User S-1-5-21-...-1105 is being logged in with a Windows
temporary profile (The profile for the user is a temporary profile.)
Reason set to 7: Profile is a Windows temporary profile
```

#### What was checked, and what it showed

| \# | Layer               | Check                                                                                        | Result                                                                                                                                                                                                                                                                                               | Evidence |
|----|-----------------------|------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------|
| 1  | Direct verification | Re-checked the FSLogix log after the AD ProfilePath was cleared and a clean sign-in occurred | `VHDRootFilePath` pointed at the real FSLogix share (`\\stavdfslogixprod012842...\avduser01_S-1-5-21-...\Profile_avduser01.VHDX`), `LogonStage=5(Logon_Complete)`, **no temp-profile warning** — this is FSLogix working correctly, not a local-profile fallback as the alternative theory predicted | NA       |
| 2  | Real root cause     | Checked the Azure Portal's file share listing directly                                       | Found multiple files literally named `CORRUPT_<guid>_Profile_avduser01.VHDX` in the `avduser01` folder, alongside one clean `Profile_avduser01.VHDX`                                                                                                                                                 | NA       |
| 3  | Fix                 | Deleted the corrupted files, user signed in again                                            | Clean attach, confirmed via log and, later, cross-session persistence                                                                                                                                                                                                                                | NA       |

#### The decisive observation

The alternative theory made a specific, checkable prediction: that Windows would fall back to a **local** profile once the AD attribute was cleared. The actual log showed the opposite — a correctly attached **FSLogix VHDX**. A theory that makes a specific prediction which the primary evidence directly contradicts should be rejected, even when the theory is well-written and internally plausible. The portal screenshot showing files explicitly named `CORRUPT_*` was the actual smoking gun — evidence that didn't need interpretation.

#### Things that were tried and did not help

- Clearing the AD user object's `ProfilePath` attribute, per the alternative theory. This did not cause any harm, but it also was not the actual fix — the corrupted containers were still present at that point, and the real fix (deleting them) is what resolved the issue on the next attempt.

#### Limitations of the evidence

- It's possible clearing the AD ProfilePath attribute had some smaller, legitimate benefit (e.g., removing an unused legacy setting) even though it wasn't the cause of the temp-profile issue — this wasn't tested in isolation, since both changes (clearing the attribute and deleting the corrupted files) happened close together.
- The original source of the VHDX corruption was not root-caused — most likely tied to the stuck-VM incident (Issue 4), where the session host was in an inconsistent state for an extended period, but this is inference, not confirmed.

#### What I would try next

1. If this recurs, check the file share for `CORRUPT_*` files first, before investigating AD attributes, GPOs, or FSLogix registry settings — it's the fastest, most direct check and was the actual answer here.
2. When any AI tool (this one included) offers a plausible-sounding explanation, check it against the most specific, falsifiable evidence available (here: the FSLogix log's own `VHDRootFilePath` and `LogonStage` fields) before acting on it, especially before making a change (like clearing an AD attribute) that could itself introduce a new variable.

#### Workaround

N/A — this was fully root-caused and fixed, not worked around.

#### Reference commands

```
# Check for corrupted containers directly
$ctx = (Get-AzStorageAccount -ResourceGroupName $SpokeRg -Name $StorageAccountName).Context
Get-AzStorageFile -ShareName "profiles" -Context $ctx | Where-Object { $_.Name -like "*CORRUPT*" }

# Verify FSLogix is attaching the REAL container, not falling back
Get-Content "C:\ProgramData\FSLogix\Logs\Profile\Profile-*.log" -Tail 60 |
    Select-String "Attached|temporary profile|VHDRootFilePath|LogonStage"
```

---

### Issue 8: `frx copy-profile` fails against the legacy profile specifically — isolated via A/B control, not fully root-caused

**Status:** Partially resolved. Migration completed via a manual fallback; the exact `frx` failure was narrowed to a specific stage but not fully root-caused.

#### Summary

`frx copy-profile`, run against `avduser01`'s legacy roaming profile (`\\vm-onprem-dc01\legacy-profiles\avduser01.V6`), consistently failed with `0x00000001` ("Incorrect function") during the registry-export stage. A systematic isolation process ruled out SMB/file access, NTFS permissions, hive readability, and general FSLogix functionality as causes — each checked independently and confirmed working. A clean-profile control test (a non-legacy, freshly created profile) using the identical `frx` command and environment succeeded without issue, proving the fault is specific to this legacy profile, not the tool or environment generally. The investigation was deliberately stopped at this point — further isolation (classifying specific stale registry references inside the loaded hive) was identified as the next step but not pursued, in favor of using a manual file-copy fallback to complete the actual migration objective within time constraints.

#### Topology / context

| Item                 | Value                                                       |
|----------------------|---------------------------------------------------------------|
| Phase affected       | Phase 6                                                     |
| Resource(s) involved | `avduser01.V6` legacy profile, `frx.exe` on `vm-avd-host-0` |
| Relevant IPs / names | SID `S-1-5-21-1103833467-2665069183-4133319136-1104`        |

#### Symptom

```
Exporting registry information
Export Profile registry data error: 0x00000001
Error copying profile (0x00000001): Incorrect function.
```

#### What was checked, and what it showed

| \# | Layer                        | Check                                                                            | Result                                                                                                                                       | Evidence                      |
|----|---------------------------------|-------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------- |---------------------------------|
| 1  | SMB/file access              | `Test-Path`, `Get-Item`, direct `.NET File.Open()` against `NTUSER.DAT` over SMB | All succeeded; file size confirmed 1,048,576 bytes                                                                                           | this conversation             |
| 2  | NTFS permissions             | `takeown` / `icacls` on the legacy profile folder                                | Succeeded; folder was simply locked to the original owning user by default, not actually corrupted or inaccessible                           | this conversation             |
| 3  | Registry hive validity       | `reg load HKU\TempAvdUser`, `reg export`                                         | Both succeeded completely — the hive itself loads and exports cleanly via plain Windows tools                                                | this conversation             |
| 4  | FSLogix/frx general function | `frx copy-profile` against a clean, non-legacy test profile                      | Succeeded, produced `FRXTEST_cleanprofile.vhdx`                                                                                              | screenshot, this conversation |
| 5  | Destination-side state       | Checked the partially-created destination VHDX                                   | Existed, 164 MiB, not attached — `frx` had gotten far enough to create a destination file before failing                                     | this conversation             |
| 6  | FSLogix's own log            | `C:\ProgramData\FSLogix\Logs\Profile\Profile-*.log`                              | Showed successful profile-data export lines elsewhere in the log, but not a clean run free of the 0x00000001 error for this specific attempt | this conversation             |

#### The decisive observation

The clean-profile control test is the single strongest piece of evidence: identical `frx` command, identical environment, identical FSLogix version — success against a clean profile, failure against the legacy one. This conclusively narrows the fault to something specific about the legacy profile's content or state (most likely within `NTUSER.DAT` itself, since that's what the registry-export stage processes), not to environment, permissions, or tooling.

#### Things that were tried and did not help

- Re-running `frx copy-profile` multiple times against the same legacy profile — consistent failure, not transient.
- Taking ownership and re-granting NTFS permissions — no change in the `frx` result, confirming this wasn't a permissions issue specifically affecting `frx`'s own access pattern.

#### Limitations of the evidence

- **Root cause within the registry-export stage was not determined.** The legacy hive contains numerous stale/mixed profile path references (e.g., `C:\Users\local_avduser01\...` alongside `C:\Users\avduser01\...`), found during investigation — but these were confirmed present, not confirmed causal. The planned next step (classifying whether `local_avduser01` references appear in profile-critical registry locations versus harmless cache/history values) was not carried out.
- No original `frx` console output was saved to a file from the first failing attempt — only the terminal text as it appeared at the time, pasted into this conversation.

#### What I would try next

1. Classify the stale registry references with targeted, read-only queries: `reg query HKU\TempAvdUser /f "local_avduser01" /s`, then narrower queries for `C:\Users\avduser01` and `avduser01` alone, to see whether these appear in locations `frx`'s registry-export step would actually process.
2. If a specific key or value is identified as suspect, test removing just that value from a *copy* of the hive (never the original) and retry `frx copy-profile` against the modified copy.
3. Check FSLogix's release notes / known issues for `0x00000001` during registry export — this may be a documented, known limitation with certain legacy profile states rather than something specific to this environment.

#### Workaround

Legacy test files were copied manually into `avduser01`'s existing, working FSLogix VHDX (mounted via `Mount-DiskImage`), rather than using `frx copy-profile`'s registry-aware migration. This successfully demonstrates data migration for the purposes of this project, but does not carry over registry-based profile settings (e.g., application configuration stored in the user's registry hive) the way a successful `frx copy-profile` would have.

#### Reference commands

```
# The control test that isolated the fault to the legacy profile specifically
& $frxPath copy-profile -filename $cleanTestVhdPath -sid $testSid -profile-path $cleanTestProfilePath -verbose
# (succeeded)
& $frxPath copy-profile -filename $destinationVhdPath -sid $sid -profile-path $legacyProfilePath -verbose
# (failed with 0x00000001 at the registry-export stage)

# Read-only classification queries (not yet run, identified as the next step)
reg query HKU\TempAvdUser /f "local_avduser01" /s
reg query HKU\TempAvdUser /f "C:\Users\avduser01" /s
```

---

### Issue 9: Legacy RDS cutover revealed a group-scoping gap, and a GPO edit briefly locked out all DC admin access

**Status:** Resolved. Cutover completed correctly; the lockout was recovered. Recovery steps are deliberately not detailed here per the project owner's request — only that it occurred and was resolved via Azure Serial Console.

#### Summary

The originally planned cutover step — removing `avduser01` from the "Remote Desktop Users" AD group — did not actually block legacy RDS access; `avduser01` could still sign in afterward. Investigation found the real controlling mechanism was a GPO user right, `SeRemoteInteractiveLogonRight` ("Allow log on through Remote Desktop Services"), granted to `GRP-AVD-USERS` — the same group used for AVD application access. A naive fix (removing `avduser01` from `GRP-AVD-USERS` directly) would have broken their AVD access too. A new, dedicated group was created and the GPO retargeted correctly. Separately, while cleaning up a related, unnecessary grant of the same right on Default Domain Controllers Policy, the policy value was inadvertently overwritten (left containing only one group, with no Administrators entry), which temporarily locked out RDP and Bastion access to the domain controller for all accounts, including the primary admin account. This was recovered via Azure Serial Console.

#### Topology / context

| Item                 | Value                                                                                           |
|----------------------|-----------------------------------------------------------------------------------------------------|
| Phase affected       | Phase 6                                                                                         |
| Resource(s) involved | `vm-onprem-rds01` (Default Domain Policy), `vm-onprem-dc01` (Default Domain Controllers Policy) |

#### Symptom

Cutover not taking effect:

```
[avduser01 still able to sign into legacy RDWeb after Remove-ADGroupMember from
"Remote Desktop Users"]
```

DC lockout:

```
[RDP and Bastion both failed with a Windows logon-rights error for all accounts]
```

#### What was checked, and what it showed

| \# | Layer                           | Check                                                                                  | Result                                                                                                                                                                              | Evidence |
|----|-----------------------------------|-------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |------------|
| 1  | Group membership after removal  | `Get-ADGroupMember -Identity "Remote Desktop Users"`                                   | `avduser01` genuinely absent — the removal itself worked correctly                                                                                                                  | NA       |
| 2  | Local admin rights              | `Get-LocalGroupMember -Group "Administrators"` on `vm-onprem-rds01`                    | `avduser01` not present — ruled out as an alternate access path                                                                                                                     | NA       |
| 3  | GPO user right                  | `secedit /export ... /areas USER_RIGHTS`, filtered for `SeRemoteInteractiveLogonRight` | Showed `GRP-AVD-USERS` as the actual grantor — the real, separate mechanism controlling RDS logon                                                                                   | NA       |
| 4  | Shared-group risk               | `Get-AzRoleAssignment` on the AVD application group                                    | Confirmed `GRP-AVD-USERS` also holds the Desktop Virtualization User role for AVD — removing `avduser01` from it would have broken AVD access                                       | NA       |
| 5  | Which GPO governs which machine | `Get-ADComputer -Identity "vm-onprem-rds01"`                                           | `CN=Computers`, not `Domain Controllers` — confirmed Default Domain Policy is the one that matters for the RDS box; Default Domain Controllers Policy only affects `vm-onprem-dc01` | NA       |
| 6  | DC lockout                      | RDP and Bastion both attempted                                                         | Both failed for all accounts, including the primary admin                                                                                                                           | NA       |
| 7  | Recovery path                   | Azure Serial Console → SAC → cmd/PowerShell channel                                    | Successful — recovery details intentionally not documented further here                                                                                                             | NA       |

#### The decisive observation

`Get-AzRoleAssignment` returning `GRP-AVD-USERS` as the principal on the AVD application group — found *before* removing `avduser01` from that group — is what prevented a second, more damaging mistake (breaking AVD access while trying to fix legacy access). Checking the blast radius of a group before modifying its membership, rather than after, is the generalizable lesson here.

#### Things that were tried and did not help

- The original "Remote Desktop Users" group removal — correct as an idea, but not the actual controlling mechanism in this environment; worth knowing that a commonly-assumed access-control group is not always the one actually in effect when a GPO user right is independently configured.

#### Limitations of the evidence

- The exact mechanism by which the Default Domain Controllers Policy edit resulted in a full value overwrite (rather than a clean removal of one entry) was not captured — likely a GPMC UI interaction issue, but not confirmed.

#### What I would try next

1. When removing one principal from a multi-value GPO user-rights-assignment list, re-export and verify the resulting value *before* applying it, rather than relying on GPMC's own UI editor exclusively.
2. Keep Azure Serial Console's access path documented and tested *before* it's needed in an emergency — this project found it worked, but only after already being locked out, which is a stressful time to be learning a new recovery tool.

#### Workaround

N/A — fully resolved, not worked around.

#### Reference commands

```
# Confirm which GPO actually governs a given machine
Get-ADComputer -Identity "<computer-name>" | Select-Object DistinguishedName

# Check the real controlling right before assuming a group's purpose
secedit /export /cfg C:\secpol-check.cfg /areas USER_RIGHTS
Select-String -Path C:\secpol-check.cfg -Pattern "SeRemoteInteractiveLogonRight"

# Check a group's full blast radius before modifying its membership
Get-AzRoleAssignment -ResourceGroupName $SpokeRg -ResourceName $AppGroupName `
    -ResourceType "Microsoft.DesktopVirtualization/applicationgroups" |
    Where-Object { $_.DisplayName -eq "<group-name>" }
```

---

### Issue 10: App Attach CIM mounting fails with ErrorCode 87 — known issue, resolved via documented VHDX fallback

**Status:** Resolved via documented fallback, not fully fixed at the root (CIM was abandoned in favor of VHDX, not debugged to a working CIM state).

#### Summary

Attempting to expand an App Attach package using CimFS (`.cim`), Microsoft's current recommended format, failed on every attempt with `Native error when mounting CIM, HResult -2147024809, ErrorCode 87` (`0x80070057`, `ERROR_INVALID_PARAMETER`). Extensive isolation ruled out network, driver, and feature-flag causes. A web search found this exact error, with identical HResult and ErrorCode, documented in two independent sources: a Microsoft Tech Community thread describing it as a known issue fixed by cumulative update KB5060829 (June 2025), and an independent technical blog attributing it to a CIM version mismatch (V3 CIM from Windows 11 packaging vs. V2 expected by older host OS versions). VHDX — Microsoft's own documented fallback format — was used instead and succeeded immediately.

#### Topology / context

| Item                 | Value                                     |
|----------------------|----------------------------------------------|
| Phase affected       | Phase 7                                   |
| Resource(s) involved | `vm-avd-host-0`, App Attach package image |

#### Symptom

```
Error expanding msix app attach package. The MSIX Application metadata expand
request failed on all Session Hosts that it was sent to. Session Host:
vm-avd-host-0, Native error when mounting CIM, HResult -2147024809, ErrorCode 87.
```

Direct local mount attempts also failed, with a related but distinct error:

```
Mount-CimDiskimage : Mounting xxxxx.cim to volume failed with Error: 'Too many
posts were made to a semaphore' ErrorCode: 298
```

#### What was checked, and what it showed

| \# | Layer                | Check                                                     | Result                                                                    |
|----|-------------------------|---------------------------------------------------------------|--------------------------------------------------------------------------- |
| 1  | Network reachability | `Test-NetConnection` to storage account port 445          | True                                                                      |
| 2  | File access          | `Test-Path` to the CIM on the share from the session host | True                                                                      |
| 3  | Identity             | Confirmed `NT AUTHORITY\SYSTEM` could access the share    | True                                                                      |
| 4  | CimFS/WCIFS drivers  | Checked driver state                                      | Present, running                                                          |
| 5  | Windows Update       | Checked for KB5129242                                     | Installed; host rebooted; error persisted regardless                      |
| 6  | Containers feature   | `VirtualMachinePlatform` / Windows Containers             | Correctly disabled, as expected                                           |
| 7  | CimDiskImage module  | Direct `Mount-CimDiskImage` test, bypassing AVD entirely  | Also failed, with the related Error 298                                   |
| 8  | Root cause research  | Web search for the exact HResult/ErrorCode combination    | Matched two independent, credible sources describing the same known issue |

#### The decisive observation

Finding the *exact* HResult and ErrorCode combination independently documented in two unrelated sources (a Microsoft community thread and a third-party technical blog), both describing the same CIM-version/OS-compatibility class of problem, turned an unexplained local failure into a recognized, bounded issue with a known workaround — rather than a mystery requiring open-ended further isolation.

#### Things that were tried and did not help

- Installing an available Windows Update (KB5129242) and rebooting — the error persisted, suggesting the specific fix-bearing update (KB5060829, per the community thread) was not the one already installed, or the cause here was the OS version mismatch described in the second source rather than purely a missing patch.

#### Limitations of the evidence

- The exact OS versions of the packaging machine and `vm-avd-host-0` were not directly compared against the V2/V3 CIM version theory from the second source — the match is plausible and consistent with the evidence, not independently proven for this specific environment.
- CIM was abandoned rather than fully resolved — if a future need specifically requires CIM (e.g., its performance advantages matter at scale), this would need further work: either installing KB5060829 specifically (confirm via `Get-HotFix`), or rebuilding the package on an OS version matching the session host's CIM version expectation.

#### What I would try next

1. Confirm `vm-avd-host-0`'s exact installed update level via `Get-HotFix` / `Get-ComputerInfo`, specifically checking for KB5060829 or later.
2. If not present, install it and retry CIM before concluding VHDX is the permanent answer.
3. Separately, confirm the packaging machine's exact Windows build, to test the V2/V3 CIM version theory directly rather than inferring it.

#### Workaround

VHDX used instead of CIM, via `msixmgr -fileType vhdx` in place of `-fileType cim`. This is an explicitly supported, documented Microsoft fallback, not an unofficial workaround — the only tradeoff is CIM's claimed performance advantage at scale, which doesn't meaningfully matter for a single-app lab.

#### Reference commands

```
# The failing CIM command
msixmgr.exe -Unpack -packagePath "app.msix" -destination "app.cim" -applyACLs -create -fileType cim -rootDirectory apps

# The working VHDX fallback
msixmgr.exe -Unpack -packagePath "app.msix" -destination "app.vhdx" -applyACLs -create -fileType vhdx -rootDirectory apps

# Check for the specific fix-bearing update
Get-HotFix | Where-Object { $_.HotFixID -eq "KB5060829" }
```

---

### Issue 11: Powering off the on-prem DC breaks new AVD sign-ins (hybrid dependency is a runtime dependency, not just a migration source)

**Status:** Confirmed by test; documented as a known architectural limitation, not fixed. Recovery after restarting the DC was not captured as evidence in this run.

#### Summary

While deciding whether the legacy VMs could be decommissioned, `vm-onprem-rds01` had been off for about a day and `vm-onprem-dc01` was off. An AVD sign-in attempt in that state failed with "We couldn't connect to the gateway because of an error." This shows the AVD environment depends on the domain controller at runtime: the session host is hybrid-joined, FSLogix reaches Azure Files with AD Kerberos, and Entra Connect runs on the DC. Profile data itself is not at risk, because the VHDX containers live in Azure Files, independent of any on-prem VM.

#### Limitations of the evidence

- Only one failed sign-in was observed, and the exact failing component (Kerberos ticket issuance, agent health checks, or something else) was not isolated. The gateway-level message suggests an early failure, but that is inference.
- Restarting the DC and confirming recovery was not captured.

#### What I would try next

1. Start the DC, retry the sign-in, and record recovery as the second half of the test.
2. For a true cutover, the options are Entra-join-only session hosts plus Entra Kerberos for Azure Files. Verify the current Microsoft Learn support matrix and whether existing FSLogix containers need re-permissioning first.

#### Workaround

Keep `vm-onprem-dc01` running. Phase 9 deallocates only `vm-onprem-rds01`, not the DC.

---

### Issue 12: Sentinel failed-sign-in detection returned no rows because no qualifying events existed

**Status:** Resolved. The pipeline worked; the test data did not satisfy the rule.

#### Summary

The analytics rule returned zero rows and ingestion looked suspect. The ingestion path (Diagnostic Setting, Log Analytics workspace, Advanced Hunting on SigninLogs) was verified working. Counting the raw `50126` events showed why the rule was right to return nothing: one user had 3 failures spread over about 40 minutes (outside the 10-minute window), another had only 2. Error `50089` (expired flow or token) also appeared and is not a bad-password failure, so it must not be counted. Generating 3 deliberate `50126` failures for one test account within a few minutes produced Sentinel incident #15, which fired the automation rule and Logic App, and an Outlook notification was received.

#### Decisive observation

A raw query for `ResultType == 50126` over the last 15 minutes, grouped by user, showed the count and timespan per user. Zero rows from the rule was a correct result, not a fault.

#### Things that were tried and did not help

Re-checking ingestion and diagnostic settings once they were already proven working.

#### Limitations of the evidence

The Logic App's Add Comment V3 action failed repeatedly ("Incident Arm id missing") and was removed, and the notification's Account Entity field was blank because of the presentation expression. The Get Accounts action itself succeeded. Both are cosmetic and were left unfixed so they would not destabilize the working chain.

#### Reference commands

```
SigninLogs
| where TimeGenerated > ago(15m)
| where ResultType == 50126
| project TimeGenerated, UserPrincipalName, ResultType, ResultDescription
| order by TimeGenerated desc
```

`New-TestFailedSignIns` in `scripts/phase6-8-troubleshooting.ps1` generates the test events for a test account only.

---

### Issue 13: `Get-AzStorageAccount` / `Get-AzADUser` silently fail to surface properties that exist on the object

**Status:** Resolved. Module/cmdlet gap, not a real config gap — found repeatedly across Phases 9, 10, and 14.

#### Summary
Three separate occasions in this project, a PowerShell cmdlet's **default output** failed to show a property that genuinely existed on the underlying object, and was initially misread as "the config is missing" before being confirmed as a tooling display gap:

1. **Phase 9:** `Get-AzStorageAccount ... | Select -ExpandProperty AzureFilesIdentityBasedAuthentication` → `Property cannot be found`. Direct property access, `(Get-AzStorageAccount ...).AzureFilesIdentityBasedAuthentication`, returned the full block correctly.
2. **Phase 10:** Same property, after a successful `Set-AzStorageAccount -EnableAzureActiveDirectoryKerberosForFile $true`, returned **nothing** via the same direct-property method on `Az.Storage 9.7.2`. `Get-Command Set-AzStorageAccount` confirmed the parameter was valid, so the set had worked — the gap was specifically in `Get-AzStorageAccount`'s return. Verified instead via `az storage account show --query "azureFilesIdentityBasedAuthentication"` (reads live from ARM, not subject to the module gap).
3. **Phase 14:** `az ad user show --id <id> --query onPremisesSyncEnabled` returned `null` for a genuinely hybrid-synced account. `az ad user show` uses the older Azure AD Graph–compatible CLI surface, which doesn't reliably populate that field. Verified instead via Microsoft Graph v1.0 directly (`az rest --method GET .../users/<id>?$select=...`), which returned `onPremisesSyncEnabled: true` plus a populated `onPremisesDistinguishedName`.

#### The decisive observation
In all three cases, switching to a different read path — direct property access instead of `-ExpandProperty`, `az cli` instead of the `Az.Storage` module, Graph v1.0 instead of the legacy `az ad` surface — immediately surfaced the value that was "missing." None of these were real configuration gaps.

#### Standing rule
A blank or missing property from an `Az.*` PowerShell cmdlet or `az ad` is not proof the underlying config is absent. Before troubleshooting the resource itself, re-check the same property via a second, independent path (`az cli --query`, Graph REST, or direct dot-property access instead of `Select -ExpandProperty`).

**Phase:** 9, 10, 14

---

### Issue 14: Cloud Shell identity and network context repeatedly produce false negatives

**Status:** Resolved / documented as standing execution-context awareness.

#### Summary
Three distinct Cloud Shell context issues surfaced across Phases 9–14, all with the same shape — a command fails not because of the target resource's config, but because of *where*/*as whom* Cloud Shell is running:

1. **403 on `Get-AzStorageShare` from Cloud Shell (Phase 9):** two-fold cause — Cloud Shell runs as its own managed identity (`MSI@50342`), not the user's own account, and had no `Storage File Data SMB Share *` role; separately, the storage account firewall (`DefaultAction: Deny`) didn't include Cloud Shell's egress IP. Resolved by running the command from `vm-avd-host-0` instead (inside the allowed VNet, domain-joined), deliberately avoiding a new MSI role grant to keep that phase discovery-only.
2. **`dsregcmd`, `Get-ItemProperty`, and other local-machine checks "not recognized" from Cloud Shell (Phase 9, and again in Phase 11's `Test-AadkerbReadiness` client-device section):** these are Windows-only cmdlets/binaries; Cloud Shell runs on Linux. Not a real failure — expected, and documented as an execution-context note rather than a bug.
3. **Cloud Shell's outbound IP differs from the local machine's and can rotate between sessions** — relevant any time a storage firewall IP allowlist is being tested; always confirm the actual egress IP from wherever the command is actually running, not the portal-detected IP.

#### Standing rule
Before troubleshooting a Cloud Shell-originated failure (403, "not recognized", firewall-rejected), first check whether the failure is explained by Cloud Shell's own identity (MSI, not the user), its OS (Linux, not Windows), or its IP (ephemeral, not fixed) — rather than the target resource.

**Phase:** 9, 11, 14

---

### Issue 15: `AzFilesHybrid` module used outside its intended scenario breaks Cloud Shell

**Status:** Resolved.

#### Summary
Provisioning the storage account's Entra Kerberos service principal was first attempted with the `AzFilesHybrid` PowerShell module. This module is built for **hybrid AD domain-join** scenarios specifically, and broke in Cloud Shell on `PSStyle` when run there. The correct cmdlet for cloud-only Entra Kerberos is `Set-AzStorageAccount -EnableAzureActiveDirectoryKerberosForFile $true`, run from the standard `Az.Storage` module in Cloud Shell PowerShell — not from the session host, and not via `AzFilesHybrid`.

#### Fix
```powershell
Set-AzStorageAccount -EnableAzureActiveDirectoryKerberosForFile $true
```

**Phase:** 11

---

### Issue 16: Six-part Entra-join + Entra Kerberos prerequisite chain for AVD (FSLogix mount, sign-in, DNS)

**Status:** Resolved. The hardest multi-layer diagnosis in the project — 14 sequential checks before the actual root cause surfaced.

#### Summary
Standing up a fully Entra-joined (no on-prem AD dependency) AVD host pool with FSLogix on Azure Files required **six separate, individually-mandatory** prerequisites; missing any one produces a different failure mode, several of them misleading:

1. **System-assigned managed identity must be explicitly attached** (`az vm identity assign`) — not on by default; its absence silently breaks Entra join with error `0x801c002d` (`GetTenantId`), surfaced via `dsregcmd /status` showing `AzureAdJoined: NO`.
2. **Per-NIC DNS override to `168.63.129.16`** — an empty per-NIC DNS setting causes the host to inherit the VNet's default DNS (the on-prem DC's IP), which then silently breaks Entra-only auth expectations. Set explicitly on the host's NIC; VNet default and other hosts left untouched.
3. **Custom RDP property `targetisaadjoined:i:1`** on the host pool — its absence produces a **generic** "check your username and password" sign-in failure for Entra-joined-only hosts, with no useful error pointing at the real cause.
4. **`defaultSharePermission=StorageFileDataSmbShareContributor`** on the storage account — mandatory as the SMB fallback authorization path for cloud-only identities; per-user RBAC alone is documented as insufficient.
5. **`kdc_enable_cloud_group_sids` tag** on both the storage account's Service Principal *and* its App Registration (two distinct Entra objects, both needed — confirmed via `Get-AzADServicePrincipal` and `Get-AzADApplication` separately).
6. **Cloud Kerberos registry keys in two separate locations** on the session host:
   - `HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount` (`CloudKerberosTicketRetrievalEnabled`, `LoadCredKeyFromProfile`)
   - `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters` (`CloudKerberosTicketRetrievalEnabled`)

Even with all six correctly in place, FSLogix still failed to mount (`FrxStatus: 31`, `Error 1265 ERROR_TRUST_FAILURE`) — see Issue 17 for the actual root cause, which sits above all six of these.

#### Leads investigated and ruled out, in order
- `CloudKerberosTicketRetrievalEnabled` registry key presence — confirmed correct, not the cause.
- OS build gate (cloud-only Entra Kerberos requires Windows 11 24H2 build 26100.8116+) — host was on 26100.9457, well above the gate. Ruled out.
- `klist cloud_debug` showing `Cloud Primary (Hybrid logon) TGT available: 0` — initially treated as a fault signal; determined this is the **expected** value for cloud-only, non-hybrid devices, not an indicator of anything wrong.
- Classic Remote Desktop app vs. Windows App (new client) — switched clients in case of weaker Cloud Kerberos ticket passthrough support in the classic client. No change in outcome; client version ruled out.
- `protocolSettings.smb.kerberosTicketEncryption` returning null — investigated as a possible RC4-vs-AES-SHA1 negotiation mismatch; determined null is the expected "use platform default" state, not a fault.
- `smbOAuthSettings` — a separate OAuth-over-SMB path for managed-identity (VM/app) access only, not interactive user sign-in. Not applicable here; ruled out.
- Preview-vs-GA documentation conflict — several Microsoft Learn pages still described cloud-only Entra Kerberos for Azure Files as "preview." Verified against Microsoft's own GA announcement (19 May 2026): confirmed GA, documentation simply hadn't caught up. This confirmed the failure was fixable, not a platform ceiling.

**Phase:** 11

---

### Issue 17: FSLogix mount fails with zero client-side error — missing Entra admin consent on the storage account's app registration

**Status:** Resolved. The actual root cause beneath Issue 16 — invisible to every client-side and storage-config check.

#### Summary
With all six prerequisites in Issue 16 confirmed correct, FSLogix still failed to mount the profile share (`FrxStatus: 31`, Event ID `1265 ERROR_TRUST_FAILURE`). A direct SMB test bypassing FSLogix (`net use Z: \\<storageaccount>.file.core.windows.net\profiles-cn /BLOCKNTLM`) produced a **password prompt** rather than a trust/DC-style error, which isolated the fault to the underlying Kerberos/SMB auth path rather than FSLogix itself. `klist` after that attempt showed **no service ticket for `cifs/<storageaccount>.file.core.windows.net` was ever requested** — only the `krbtgt` referral ticket — meaning the client wasn't even attempting to request a ticket for the storage SPN.

Running `Test-AadkerbReadiness` (the `AzureFilesToolkit` PowerShell module, from Cloud Shell) — a purpose-built readiness diagnostic covering storage config, Entra app registration/consent state, Conditional Access, recent sign-in failures, and RBAC in one pass — surfaced the actual cause directly from Entra sign-in logs: repeated **Error 90008** for the test user against the storage account's auto-created app registration, meaning the user/admin had not consented to the Graph permission `openid profile User.Read`.

This is an **application-level consent gate above Kerberos ticket issuance**. Without it, Entra silently declines to let the client request a service ticket for the storage SPN — no error surfaces at the device or Kerberos-cache level, and `klist cloud_debug` shows a healthy referral TGT throughout, which is exactly why this was invisible to every check in Issue 16.

#### Fix
```powershell
az ad app permission admin-consent --id <storage-app-id>
```
Followed by a **full sign-out/sign-in** as the test user — `klist purge` alone does not pick up a new consent grant.

#### Verification
```cmd
net use Z: \\<storageaccount>.file.core.windows.net\profiles-cn
```
Succeeded immediately after the fix; subsequent AVD sign-in showed a clean FSLogix mount (`Profile load: Status: 0  Reason: 0  Error: 0`).

**Phase:** 11

---

### Issue 18: Diagnostic script noise — a false-positive manifest-tag check, and Windows-only checks failing from Linux Cloud Shell

**Status:** No action needed — both are tool/environment noise, not real gaps.

#### Summary
Two sub-issues surfaced while running `Test-AadkerbReadiness` (see Issue 17):
1. The script reported `[FAIL] Application manifest tag 'kdc_enable_cloud_group_sids' is MISSING`, despite the tag being independently confirmed present via `$sp.Tag` and `$app.Tag` on both the Service Principal and the Application objects. Treated as a script false positive (stale cache or a different property path), not a real gap — documented for anyone re-running this diagnostic later.
2. Section 5 of the same script (Client Device checks) threw errors for `Get-CimInstance`, `dsregcmd`, `Get-Service`, and `Test-NetConnection` — all Windows-only, and the script was run from Linux-based Cloud Shell. Expected; client-device checks need to run from the session host itself. (Same root cause as Issue 14.)

**Phase:** 11

---

### Issue 19: App Attach fails with a generic "failed to retrieve access keys" error — 13 causes ruled out, root cause unconfirmed

**Status:** Open / blocked. MS support case drafted, not filed. Documented as a known limitation for now.

#### Summary
`Import-AzWvdAppAttachPackageInfo` consistently failed with:
```
Failed to retrieve access keys for storage accounts. Cannot proceed with AAD app attach workflow.
```

**Ruled out (confirmed not the cause):**
- RBAC at share and account scope for both AVD service principals
- `allowSharedKeyAccess` forced true
- Host VM managed identity granted Storage Account Key Operator Service Role
- Firewall fully open (`DefaultAction=Allow`, `AzureServices` bypass) and re-tightened — no change either way
- Admin's own RBAC (Owner + Contributor) and network/IP access
- Host **device object** added to the hosts group with Storage File Data SMB Share Reader
- `Az.DesktopVirtualization` module version (6.0.0, well above the 4.2.1 minimum)
- Storage account identity — isolation test against an old, proven-working storage account reproduced the identical error

**Two real but separate bugs found along the way (not the root cause):**
- The Portal App Attach wizard's file-picker throws a generic `401` in its UI toast; the real underlying failure, visible only in DevTools Network tab, is `403 AuthorizationFailure` on the Azure Files data-plane list call — a portal UI bug independent of the import failure, confirmed by bypassing the picker with UNC path input (same original error still occurs).
- Testing with a legacy on-prem admin account showed no PRT, which is expected (that account was never meant to get a PRT on an Entra-only host) — not a real lead. Re-testing with the actual intended identity confirmed PRT/CloudTgt were both healthy.

**Current best lead (unconfirmed):** per Microsoft Learn, VHDX/CimFS images are mounted using the session host's **own computer/device account**, not the AVD service principals. Granting that device object SMB Share Reader via its group did not resolve the issue — suggesting either a different role is needed for that identity, or a genuine platform gap exists for Entra-only (non-hybrid) host pools.

#### Debugging technique that mattered most
Logic Apps/ARM API error surfaces in the portal (toast messages, run-history status) are frequently generic or wrong. For any Azure API-backed failure, check the browser DevTools Network tab for the real underlying HTTP status/response before trusting the portal's own error message. (This technique recurs in Issue 20 below, in a different subsystem.)

**Phase:** 12

---

### Issue 20: Sentinel/SOAR Logic App — five distinct playbook and portal issues

**Status:** Resolved (all five).

#### 20a — Incidents stay `New`, never close, despite the Logic App "succeeding"
**Cause:** the deployed playbook had previously been simplified to notify-only (no close/classify step) after earlier bugs with a different action version — a silent scope reduction, not visible from run history (green/Succeeded throughout, since the notify step genuinely worked).
**Fix:** rebuilt with a single `Update_incident` (V2) action handling close + classification + comment + tags together.

#### 20b — Run history shows `status: Failed` with `code: null, message: null`
**Cause:** `ApiConnection` action failures in Logic Apps frequently leave action-level error fields empty in run history; the real HTTP status/response body is only available via the action's `outputsLink`/`inputsLink`.
**Fix/technique:**
```bash
OUTPUTS_URL=$(az rest --method get \
  --url ".../workflows/<app>/runs/<runId>/actions/<actionName>?api-version=2019-05-01" \
  -o json | jq -r '.properties.outputsLink.uri')
curl -s "$OUTPUTS_URL" | jq .
```
This surfaced every real error in this phase; the run-history UI alone never did.

#### 20c — `incidentArmId` resolves to empty / "Incident Arm id missing"
Two distinct causes:
1. Stray whitespace after `@` in an expression (`"@   triggerBody()?...`) — Logic Apps silently treats anything after `@` with leading whitespace as a literal string, not an expression, and raises no syntax error. Fix: remove all whitespace between `@` and the expression.
2. Testing via "Run Trigger" in the designer sends an empty HTTP body (`Content-Length: 0`) — expected, unrelated to any real bug. Correct manual test: Sentinel Incidents blade → open an incident → **Actions → Run playbook**, which sends the genuine incident payload.

#### 20d — `Owner is not an ObjectId or UPN`
**Cause:** `"ownerAction": "Assign"` combined with `"owner": null` fails the connector's validation.
**Fix:** use `"ownerAction": "Unassign"` and omit `owner` entirely when not assigning to a specific person.

#### 20e — Tags don't appear on the incident despite the action succeeding
**Cause:** `tagsToAdd.TagsToAdd` must be an array of objects shaped `{"Tag": "value"}`, not plain strings.
```json
"tagsToAdd": { "TagsToAdd": [
    {"Tag": "SOC-Simulation"}, {"Tag": "MITRE-T1110"},
    {"Tag": "FalsePositive-Test"}, {"Tag": "AVD-Lab"}
]}
```

**Phase:** 12

---

### Issue 21: Sentinel portal/RBAC status badges and connection status are misleading

**Status:** Resolved (both).

#### 21a — "Missing permissions" badge on the automation rule's playbook selector, despite correct RBAC
**Cause:** stale/cached portal UI check. Confirmed via direct ARM GET (twice) that the correct service principal (`Azure Security Insights`) already held `Microsoft Sentinel Automation Contributor` on the resource group, and the automation rule was already correctly wired to the Logic App throughout.
**Lesson:** when a portal permission/status badge contradicts a direct API check, trust the API.

#### 21b — Logic App connection shows "Connected" but Sentinel API calls still fail authorization
**Cause:** "Connected" on an API Connection only confirms the OAuth handshake succeeded — it says nothing about whether that identity has rights on the target resource. The connection's underlying account had zero Sentinel role on the workspace itself; `Automation Contributor` on the resource group governs whether *Sentinel's own service* can invoke the playbook, not whether the connection's own user identity can call Update Incident.
**Fix:** grant the connection's underlying identity an explicit Sentinel data-plane role (e.g., **Microsoft Sentinel Responder**) scoped to the workspace.

#### Note: Defender portal vs. Sentinel-native incident numbering
`security.microsoft.com/incidents/N` and the `SecurityIncident` KQL table's `IncidentNumber` are different numbering schemes for the same incident. Match by title/timestamp, not number, when cross-checking between the two UIs.

**Phase:** 12

---

### Issue 22: General Az/Graph cmdlet pitfalls collected across Phases 11–12

**Status:** Reference notes, not individual incidents.

- `Get-AzADServicePrincipal -DisplayName` does partial/contains matching and can return multiple unexpected results — use `-ApplicationId` with the known first-party AppId when looking up a specific service principal.
- `Get-AzADDevice` does not exist in the Az PowerShell module — use the Microsoft Graph module (`Get-MgDevice`, requires `Connect-MgGraph`) instead.
- `Add-AzADGroupMember` uses the parameter `-TargetGroupObjectId`, not `-GroupObjectId`.

**Phase:** 11, 12

---

### Issue 23: Entra-joined sign-in falls back to local Negotiate/Kerberos — a second, separate RBAC role was missing

**Status:** Resolved.

#### Summary
Sign-in failed with `0xc000006d` / substatus `0xc0000022`. Security log Event 4625 showed the attempt falling back to local Negotiate/Kerberos (`SubjectDomainName: WORKGROUP`, no realm) rather than completing Entra auth.

**Ruled out:**
- App-group RBAC (`Desktop Virtualization User`) — present and correct, but necessary, not sufficient
- Password correctness — reset and confirmed
- Conditional Access policy scope — user confirmed out of scope for `avd-require-mfa`
- RDP SSO properties (`targetisaadjoined:i:1`, `enablerdsaadauth:i:1`) — both already present and correct
- Local `Remote Desktop Users` group SID — correct; the `CONTOSO\` display name shown was cosmetic, caused by stale `onPremisesSamAccountName`/UPN/domainName attributes still cached in Entra despite sync being disabled, not evidence of a real on-prem dependency
- Device registration state — empty for both the test user and a control user, ruled out as a differentiator
- `onPremisesImmutableId` / `onPremisesSecurityIdentifier` — both stale from the prior hybrid state, cleared, no effect
- Authentication Methods Policy v2.0 and Security Defaults — both confirmed not the blocker

**Real cause:** A second, separate RBAC role was missing — **Virtual Machine User Login**, required at VM/resource-group scope, distinct from **Desktop Virtualization User** on the AVD application group. The app-group role governs access to the published resource; the VM-scope role governs the actual session-host sign-in. Directly-created test users had this role from the start; the group the migrated user was placed into never did.

**Diagnostic technique:** Security log 4625's fallback-to-local-Negotiate detail prompted a Microsoft Learn documentation comparison against the exact role assignments present — the doc's distinction between the two roles as separate, both-required, was the missing piece.

#### Fix
```powershell
New-AzRoleAssignment -ObjectId <group-object-id> `
  -RoleDefinitionName "Virtual Machine User Login" `
  -Scope "/subscriptions/<sub>/resourceGroups/<rg>"
```

**Phase:** 13

---

### Issue 24: FSLogix fails after successful cloud-only sign-in — profile never migrated off the legacy AD-based storage account

**Status:** Resolved (see Issues 25–26 for the recovery path).

#### Summary
Sign-in succeeded (valid PRT, `CloudTgt: YES`), but FSLogix failed to attach the profile container; Windows fell back to a fresh/local profile with no prior Desktop/Documents content visible.

**Ruled out, cheapest/most-decisive checks first:**
1. **Storage firewall `IpRules`** — initially looked empty/incomplete because `Get-AzStorageAccountNetworkRuleSet`'s **default table view truncates array output**, misread as "only one IP present." Reading `.IpRules` directly showed the rule set was already correct. Costly misread — now a standing checklist item (see Issue 27).
2. TCP 445 connectivity — confirmed open.
3. AADKERB — confirmed enabled via `AzureFilesIdentityBasedAuth`.
4. RBAC (`Storage File Data SMB Share Contributor`) — confirmed correctly assigned at account scope.
5. **Entra sign-in logs**, filtered to the storage account resource at the exact FSLogix attach timestamp — showed a clean **Success** entry, correct egress IP, no Conditional Access block. This single check ruled out the entire identity/network layer at once and redirected diagnosis to the profile container itself.

**Real cause:** the original profile VHDX never migrated with the identity — it remained on a separate, legacy storage account still configured for on-premises AD-based identity (`DirectoryServiceOptions: AD`). The new cloud-side storage account held only an empty, auto-provisioned container. A cloud-only identity has no on-prem Kerberos ticket and is structurally unable to authenticate to an AD-based share — an architectural mismatch, not a misconfiguration.

**Phase:** 13

---

### Issue 25: Container-to-container VHDX copy produces a hash mismatch

**Status:** Resolved via standing rule — always verify, never trust size alone.

#### Summary
A direct copy of the original profile VHDX from the legacy storage account to the new one completed without error and matched the source's byte size exactly — but `Get-FileHash` (SHA-256) comparison showed **different hashes** despite matching size. Whether the mismatch originated in transit or reflected pre-existing source corruption could not be determined within scope.

#### Standing rule
Treat whole-container copies of FSLogix VHDX files across storage accounts as untrustworthy by default. Matching file size is not sufficient evidence of a clean copy — a post-copy hash comparison (`Get-FileHash` on both source and destination) is a mandatory step before reusing any copied container.

**Phase:** 13

---

### Issue 26: Offline FSLogix container editing causes reproducible `ValidateRegistryImportFile` failure

**Status:** Resolved — standing rule established.

#### Summary
A profile VHDX mounted successfully at the disk level (`Mount-DiskImage` succeeds, volume reports healthy NTFS) and files could be freely copied into it. But every subsequent FSLogix attach attempt rejected the container:
```
ERROR: ValidateRegistryImportFile failed.
ErrorCode set to 13 - Message: The data is invalid.
```
Reproduced identically across multiple sign-in attempts — not intermittent. The mounted volume's files remained fully readable and intact throughout (`Get-ChildItem` confirmed correct content) — this is distinct from ordinary disk/file corruption; the container is rejected specifically by FSLogix's own post-attach validation step.

**Real cause:** writing to a FSLogix container's contents **outside a live, FSLogix-managed Windows session** invalidates the container's embedded registry hive state — even a simple, successful-looking file copy performed while the VHDX is mounted by an admin account outside an active FSLogix attach/session cycle. FSLogix's validation checks internal registry hive/metadata consistency that a routine offline file copy does not preserve.

#### Fix / standing rule
1. Do not attempt to repair a container that has failed this way — delete it.
2. Let FSLogix auto-provision a genuinely fresh container through a normal sign-in.
3. To restore data into the new container, copy it in **from within the user's own live, authenticated session** (e.g., `Copy-Item` run as the signed-in user in an active RDP/AVD session) — never by mounting the container offline a second time.
4. Force a full sign-out/sign-in cycle afterward and confirm via the FSLogix log (`Attached vhd(x) successfully` / `LoadProfile successful.`, no `ValidateRegistryImportFile` errors) rather than assuming success from one session.

**Standing rule, carried forward to all future phases:** FSLogix containers are only ever modified through a live, authenticated user session. Offline mounting is acceptable only for read-only inspection/recovery — never for writing.

**Phase:** 13

---

### Issue 27: PowerShell default table-view output silently drops/truncates collection properties

**Status:** Standing checklist item, not a single incident — recurred twice.

#### Summary
Two confirmed cases of the same pitfall:
1. `Get-AzStorageAccountNetworkRuleSet`'s default table view truncates `IpRules` array output, misread as "only one IP present" when the rule set was actually already correct (see Issue 24).
2. `az network vnet list --query "...dhcpOptions.dnsServers"` returns **blank in table (`-o table`) output** even when a value exists — the table formatter silently drops nested fields (see Issue 28).

#### Standing rule
Never conclude a collection-type or nested property is empty/incomplete from a cmdlet's or CLI's default **table** view. Always access the property directly (`(Get-SomeCmdlet ...).PropertyName`) or re-run with `-o json` before treating a table-view blank as confirmed.

**Phase:** 13, 14

---

### Issue 28: Proactive dependency audit caught a stale DNS setting on the hub VNet before DC retirement

**Status:** Resolved — caught proactively, not by a failure.

#### Summary
No failure was observed directly. A proactive dependency audit ahead of deallocating the on-prem DC found `vnet-onprem-prod-01`'s DHCP custom DNS setting was still `10.100.1.4` (the DC's IP) — left over from before the spoke VNet's equivalent setting was cleaned up in Phase 13. Any future VM deployed into that VNet without a per-NIC DNS override would have silently inherited a dead DNS server.

(Found via the table-view DNS blank described in Issue 27 — the audit nearly missed this because `-o table` showed nothing; `-o json` revealed the stale value.)

#### Fix
```bash
az network vnet update -g rg-onprem-prod-centralindia-001 -n vnet-onprem-prod-01 --dns-servers ""
```

**Phase:** 14

---

### Issue 29: Hybrid password operations fail with Error 120013 once the source DC is gone — expected, not a bug

**Status:** No fix needed — documented as expected behavior and used as test evidence.

#### Summary
Password reset for a hybrid-synced test user failed in both the Entra portal ("we're not able to reset this user's password right now") and via CLI (`az ad user update --password ...` → `Error Code: 120013`).

**Real cause:** `120013` is Entra's on-premises write-back sync failure. For a hybrid account under Password Hash Sync with writeback or Pass-Through Authentication, a password change at the cloud layer must propagate back to the source on-prem AD object. With the DC deallocated, that write-back leg has nothing to reach, and Entra correctly refuses the operation rather than letting cloud and on-prem passwords desync.

**Resolution:** none needed. This was used directly as the primary evidence for the Phase 14 hybrid-identity-dependency test — a password-sync failure is a more specific diagnostic signal than a generic sign-in failure, since it isolates the problem to the on-prem write-back dependency specifically, with no live sign-in attempt required.

**Phase:** 14

---

### Issue 30: Powering off the on-prem DC breaks new AVD sign-ins (runtime dependency, not just a migration source)

**Status:** Confirmed by test, documented as a known architectural limitation — superseded in Phase 11–14 scope by the Entra-only migration path (Issues 16–17, 23–26), but kept here as the original evidence that motivated it.

> This duplicates Issue 11 in the existing Phase 1–8 log and is retained there as the primary record. See Issue 11 above; Phases 9–14 build directly on top of that finding by removing the on-prem DC dependency entirely for the migrated host pool.

**Phase:** 8 (original finding) → addressed architecturally in 11–14
## Evidence checklist

### For Issue 1 specifically

- the original Edge error: docs/images/phase-15/Screenshot (149).png
- TSL error: docs/images/phase-15/Screenshot (146).png

### For Issue 2 specifically

- installdns-error.txt: docs/evidence/phase15-installdns-error.txt

### For Issue 3 specifically

- Covered by the Phase 4 evidence checklist directly — see docs/phase-4-azure-files-fslogix/README.md, which already includes the AD join verification, the quota-parameter fallback note, and the RBAC/IAM screenshot showing both groups by their real names. No separate Phase 10 screenshots needed for this issue; the Phase 4 evidence IS the record of how it was resolved.

### For Issues 6 and 7 specifically

- docs/images/phase-5/04-phase5-fslogix-standard-config.png — already in Phase 5's checklist, doubles as evidence here
- docs/images/phase-5/05-phase5-vhdx-created-usernamefirst.png — already in Phase 5's checklist; also shows the duplicate-container state if captured before cleanup
- docs/images/phase-15/07-phase10-corrupt-vhdx-files.png — the portal listing showing the `CORRUPT_<guid>_Profile_avduser01.VHDX` files, before deletion — this is the single most valuable screenshot for Issue 7, the actual smoking gun

### For Issues 8 and 9 specifically

- Covered by Phase 6's own evidence checklist in docs/phase-6-migration-cutover/README.md — the `frx` failure/control-test comparison, the shared-group discovery, and the final confirmed-denied cutover screenshot all double as Phase 10 evidence. No separate Phase 10 screenshots needed for these two issues.

### For Issues 13-30 (Phases 9-14)

No screenshot evidence was captured for this range — these phases ran primarily through Cloud Shell/CLI sessions and Entra sign-in log review rather than portal screenshots. Command output and log excerpts are inline in each issue above.

## Lessons

- A phase can pass its own checklist and still fail the next phase — verification should test the thing the *next* phase depends on, not just the phase's own success criteria.
- A capture or log that returns nothing is only evidence if you confirmed the tool was actually running/working during the test.
- Read stderr, not just "Succeeded" in command output.
- Installing a Windows Feature and registering that role into a service's own deployment config (RDS, and likely others) are two separate operations with two separate sources of truth. When one check contradicts another (`Get-WindowsFeature` says Installed, `Get-RDServer` disagrees), that contradiction is itself the most useful diagnostic — don't discard it as noise, it usually names which layer is actually broken.
- If a Server Manager wizard reboots the VM mid-sequence, don't assume it's a normal, wizard-triggered restart. Confirm afterward that every step the wizard was supposed to complete actually did — a role can show `Installed` while the deployment it belongs to is left half-configured.
- When isolating a "can't reach this page" browser error, test with a command-line HTTP client (`Invoke-WebRequest`) both locally (`localhost`) and remotely (full FQDN) before assuming the server is broken. If both return `200 OK`, the problem is the browser, not the infrastructure — stop debugging IIS/NSG/DNS and look at the client instead. `-SkipCertificateCheck` only exists in PowerShell 7+; on Windows PowerShell 5.1 (the default on Server 2022) use a `TrustAllCertsPolicy` type override instead, or the command will fail with a parameter-binding error that looks unrelated to the actual test.
- Edge on Windows Server can fail silently against a self-signed certificate in ways that don't produce the normal certificate-warning interstitial — it can present as a generic "can't reach this page" instead. If Edge fails but a raw HTTP client succeeds, try Internet Explorer before assuming anything is wrong with the server.
- When an error names a specific, plausible real-world conflict (a resource that already exists, a role already installed), check that literal claim before restructuring the command's syntax. Rewriting the command can accidentally change what's being asked rather than fix anything, and can burn time on a non-problem while the real one goes unaddressed. Read the error for what it says before assuming it's a parser bug.
- Before guessing a second parameter name after a "parameter cannot be found" error (especially around GiB/GB/TB unit-naming, which Microsoft has not applied consistently across all Az.* cmdlets), run `Get-Command <cmdlet> -Syntax` and check the real, installed parameter list. Two wrong guesses in a row is a signal to stop guessing, not try a third variant.
- Azure RBAC role assignments by object ID work regardless of what an AD object's display name is — but any later script or command that looks the same object up by *name* will silently fail if that name is only an assumption. Confirm an AD group's real name directly (`Get-ADGroup -Filter "ObjectGUID -eq '<id>'"`) before writing it into a script, rather than relying on what a variable or comment calls it.
- Check vendor documentation for warnings *before* applying a configuration change, not just when troubleshooting afterward — Microsoft's own docs directly warned that FlipFlopProfileDirectoryName orphans existing containers, which turned a surprising symptom into an expected, already-understood outcome.
- When any explanation (including from another AI tool) makes a specific, checkable prediction, verify it against the most direct evidence available before acting on it — especially before a change that introduces a new variable. A plausible, well-written explanation is not the same as a correct one; the FSLogix log's own `VHDRootFilePath` and `LogonStage` fields directly contradicted an alternative theory that would have sent troubleshooting in the wrong direction.
- A file literally named `CORRUPT_*` in a portal listing is the single fastest, least-ambiguous diagnostic signal available — check for it before investigating more complex, less direct causes (AD attributes, registry settings, GPOs).
- An A/B control test (the same operation against a known-clean input versus the actual problem input) is one of the most efficient ways to isolate whether a failure is environmental/tooling versus specific to the one input — it turned an open-ended "why does frx fail" question into a bounded, well-evidenced finding without needing to fully resolve the underlying cause.
- Before removing a principal from a group to restrict one kind of access, check every other place that same group is used (`Get-AzRoleAssignment`, other GPOs) — a group created for one purpose often gets reused for another over the life of a project, and removing membership can silently break the second purpose.
- When editing a GPO user-rights-assignment value that currently holds multiple principals, verify the resulting value after the edit, before applying it — removing one entry through a GUI editor can sometimes replace the whole value rather than cleanly subtracting one entry, which can be severe when the right in question controls administrative access.
- A blank or missing property from an Az.* cmdlet or `az ad` is not proof the config is absent — cross-check via a second read path (direct dot-property access, `az cli --query`, or Graph REST) before troubleshooting the resource itself.
- Never trust a cmdlet's or CLI's default **table** view for a collection or nested property — it can silently truncate or blank a value that's actually present; re-run with direct property access or `-o json` before concluding something is missing.
- Cloud Shell runs as its own managed identity, on Linux, from a rotating IP — a 403, a "not recognized" error, or a firewall rejection from Cloud Shell may be explained by one of those three facts about Cloud Shell itself, not by the target resource.
- An error with zero client-side signal (healthy TGT, healthy PRT, no Kerberos-cache anomaly) can still have an application-level cause sitting above the layer you're inspecting — Entra admin consent gates service-ticket issuance silently, with no trace in `klist`/`dsregcmd`.
- A whole-container file copy matching in size is not proof of a clean copy — hash the source and destination before trusting a copied FSLogix container.
- FSLogix containers are only ever safely modified from within a live, authenticated user session — offline mounting is for read-only recovery, never for writing.
