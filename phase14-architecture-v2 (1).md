## Architecture
# As-built architecture: Part 2 (cloud-native, Phases 9-14) — final state

```mermaid
flowchart TB
    USER01(["avduser01<br/>cloud-native"])
    USER02(["avduser02<br/>hybrid control"])
    ADMIN(["Admin<br/>azlabadmin"])
    EID["Microsoft Entra ID<br/>Cloud Kerberos trust<br/>sign-in logs"]

    subgraph AVDCP["AVD control plane - Microsoft managed"]
        WS["ws-avd-prod<br/>workspace"]
        AG2["ag-avd-desktop-02<br/>desktop app group"]
        HP2["hp-avd-prod-02<br/>Entra-joined host pool"]
        AAP["notepadplusplus-avdlab<br/>App Attach package<br/>BLOCKED, never mounted"]:::blocked
        BRK["Broker / Gateway / Diagnostics<br/>wvd.microsoft.com :443"]
    end

    subgraph ONPREM["vnet-onprem-prod-01 - rg-onprem-prod-centralindia-001"]
        DC["vm-onprem-dc01<br/>AD DS, DNS, Entra Connect<br/>DEALLOCATED 2026-10-19"]:::deallocated
        RDS["vm-onprem-rds01<br/>legacy RDS farm<br/>DEALLOCATED 2026-10-19"]:::deallocated
        SNAP["snap-vm-onprem-dc01-osdisk-20261019<br/>OS disk snapshot<br/>retained permanently"]:::snapshot
        PIPDC["Public IP (DC)<br/>RDP 3389"]:::exposure
        BAS1["Azure Bastion"]

        DC -.->|"snapshotted before deallocation"| SNAP
    end

    subgraph SPOKE["vnet-spoke-avd-prod-01 - rg-avd-prod-centralindia-001"]
        SH1["vm-avd-host-1<br/>Win11 multi-session, D2s_v5<br/>Entra-joined ONLY, cloud Kerberos<br/>RUNNING - DC-off validated"]
        PIPH1["pip-avd-host-1-temp<br/>Standard static public IP"]:::exposure
        BAS2["Azure Bastion"]
    end

    NAT["NAT Gateway<br/>production target - NOT deployed<br/>replaces per-VM public IPs"]:::planned

    subgraph STG["stavdfslogixcn01 - AADKERB - zero on-prem AD dependency"]
        PROF["profiles-cn share<br/>FSLogix VHDX, avduser01"]
        MSIX["msix-apps-cn share<br/>unused - App Attach never worked"]
    end

    subgraph SECOPS["Security operations - validated DC-off, Phase 14 Test 5"]
        LAW["law-avd-secops-001"]
        DCR["dcr-avd-failedsignin"]
        SENT["Microsoft Sentinel<br/>DET-AVD-Repeated-Failed-SignIns"]
        LA["la-avd-soc-001<br/>Incident #12: New to Closed/FalsePositive<br/>in 18s, zero manual intervention"]
        MAIL["Outlook notification"]
    end

    USER01 -->|"1. sign in - PASSES, DC offline"| EID
    USER01 -->|"2. feed + connect"| WS
    USER02 -.->|"1. sign in / password ops - FAILS<br/>Error 120013, on-prem sync writeback"| EID
    WS --- AG2
    AG2 --- HP2
    HP2 --- BRK
    AAP -.->|"never successfully assigned"| HP2

    SH1 -->|"agent + RDP reverse connect, outbound 443"| PIPH1
    PIPH1 --> BRK
    SH1 -.->|"target egress path"| NAT
    NAT -.-> BRK

    DC -.->|"RETIRED - no longer a dependency<br/>confirmed via dsregcmd/klist, Test 1"| SH1
    USER02 -.->|"hybrid-synced identity<br/>onPremisesDistinguishedName confirmed<br/>DEPENDENT on DC - now broken"| DC
    SH1 -->|"cloud Kerberos, SMB 445<br/>KERBEROS.MICROSOFTONLINE.COM tickets only"| PROF

    ADMIN -->|"RDP 3389"| PIPH1
    ADMIN -->|"browser"| BAS1
    ADMIN -->|"browser"| BAS2
    BAS1 -.-> DC
    BAS2 --> SH1

    EID -->|"SigninLogs via diagnostic setting"| LAW
    DCR --> LAW
    LAW --> SENT
    SENT -->|"incident + automation rule"| LA
    LA -->|"azuresentinel + outlook API connections"| MAIL

    classDef planned stroke-dasharray:5 5,stroke:#888,fill:#f4f4f4,color:#555
    classDef exposure stroke:#d9822b,stroke-width:2px
    classDef deallocated stroke:#dc3545,stroke-width:2px,fill:#f8d7da,color:#721c24
    classDef snapshot stroke:#17a2b8,stroke-width:2px,fill:#d1ecf1,color:#0c5460
    classDef blocked stroke:#ffc107,stroke-width:2px,fill:#fff3cd,color:#856404
```

**Legend:** dashed grey node = target, not deployed. Orange nodes = public IPs
(inbound RDP exposure). Red nodes = deallocated (DC, RDS01). Blue node = permanent
snapshot artifact. Yellow node = documented blocked feature (App Attach).

The DC-to-host dependency from Part 1 is now **retired**, not live — Phase 14
confirmed via `dsregcmd`/`klist` that avduser01's sign-in, FSLogix mount, and the
Sentinel/SOAR pipeline all function with the DC fully offline. The dashed line from
avduser02 to the DC shows the one dependency that's still real: a hybrid identity's
password/sync operations, which now fail (`Error 120013`) with no source DC to
write back to — this is the expected, documented outcome for the control account,
not a defect.

Region: Central India. Resource names match the Azure Resource Visualizer export.
