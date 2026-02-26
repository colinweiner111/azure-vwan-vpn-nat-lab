# Azure vWAN VPN NAT Lab — Public IP Range Translation

> Based on [azure-vwan-secure-hub-lab](https://github.com/colinweiner111/azure-vwan-secure-hub-lab), extended with **VPN S2S NAT rules** that translate branch private address space to public IP ranges.

This lab demonstrates **Static NAT on Azure Virtual WAN VPN Gateways** using public (non-RFC 1918) IP ranges as the external/translated address space. It follows the patterns described in [Configure NAT rules for your Virtual WAN VPN gateway](https://learn.microsoft.com/en-us/azure/virtual-wan/nat-rules-vpn-gateway).

---

## Why NAT with Public IP Ranges?

Typical VPN NAT demos translate one private range to another (e.g., `10.x` → `172.x`). This lab uses **public IP ranges** as the NAT external mapping to demonstrate scenarios such as:

- **Compliance boundaries** — branch traffic entering the vWAN fabric appears as a public range, creating a clear trust boundary between on-premises and cloud
- **Multi-tenant isolation** — different branches (even with overlapping private space) can each be mapped to unique, easily identifiable public ranges
- **Routing clarity** — when checking effective routes or firewall logs, NATted traffic from branches is immediately distinguishable from spoke-to-spoke or spoke-to-internet flows

The lab uses [RFC 5737](https://datatracker.ietf.org/doc/html/rfc5737) documentation ranges which are reserved, non-routable, and safe for lab use:

| Range | RFC Name | Used For |
|---|---|---|
| `203.0.113.0/24` | TEST-NET-3 | Hub1 NAT external mapping |
| `198.51.100.0/24` | TEST-NET-2 | Hub2 NAT external mapping |

---

## Architecture

```
                    ┌──────────────────────────────────────────────────────────────────┐
                    │                       Azure Virtual WAN                          │
                    │                                                                  │
  ┌──────────┐     │   ┌─────────────────────┐       ┌─────────────────────┐          │
  │ Branch 1 │     │   │       Hub 1          │       │       Hub 2          │          │
  │10.100.0/24│────┼──▶│  VPN GW + NAT Rules  │       │  VPN GW + NAT Rules  │          │
  │          │     │   │                     │       │                     │          │
  │ branch1- │     │   │  IngressSnat:       │       │  IngressSnat:       │          │
  │ vm       │     │   │  10.100.0.0/24      │       │  10.100.0.0/24      │          │
  │          │     │   │    → 203.0.113.0/24 │       │    → 198.51.100.0/24│          │
  └──────────┘     │   │                     │       │                     │          │
                    │   │  EgressSnat:        │       │  EgressSnat:        │          │
                    │   │  10.100.0.0/24      │       │  10.100.0.0/24      │          │
                    │   │    → 203.0.113.0/24 │       │    → 198.51.100.0/24│          │
                    │   │                     │       │                     │          │
                    │   │  Azure Firewall     │       │  Azure Firewall     │          │
                    │   │  (Routing Intent)   │       │  (Routing Intent)   │          │
                    │   └────┬──────────┬─────┘       └────┬──────────┬─────┘          │
                    │        │          │                   │          │                │
                    │   ┌────┴───┐ ┌────┴───┐         ┌────┴───┐ ┌────┴───┐           │
                    │   │Spoke 1 │ │Spoke 2 │         │Spoke 1 │ │Spoke 2 │           │
                    │   │172.16  │ │172.16  │         │172.16  │ │172.16  │           │
                    │   │.1.0/24 │ │.2.0/24 │         │.3.0/24 │ │.4.0/24 │           │
                    │   └────────┘ └────────┘         └────────┘ └────────┘           │
                    └──────────────────────────────────────────────────────────────────┘

  NAT Effect:
  ───────────
  When hub1-spoke1-vm runs tcpdump, traffic FROM branch1-vm appears as 203.0.113.x
  When hub2-spoke1-vm runs tcpdump, traffic FROM branch1-vm appears as 198.51.100.x
  The branch VM's actual IP (10.100.0.x) is never seen by spoke VMs.
```

---

## How VPN NAT Works

### NAT Rule Types

Each hub VPN gateway has two NAT rules per branch connection:

| Rule | Direction | Effect |
|---|---|---|
| **IngressSnat** | Branch → Hub | Source IP `10.100.0.x` translated to `203.0.113.x` (Hub1) |
| **EgressSnat** | Hub → Branch | Destination IP `203.0.113.x` translated back to `10.100.0.x` |

### BGP Route Translation

The `enableBgpRouteTranslation` flag on the VPN gateway ensures that:
- Routes advertised **into** the hub from the branch are automatically translated (the hub learns `203.0.113.0/24` instead of `10.100.0.0/24`)
- Spokes, other branches, and ExpressRoute connections all see the **post-NAT** prefix
- The DefaultRouteTable shows `203.0.113.0/24` with next hop `VPN_S2S_Gateway`

### Packet Flow (Branch → Spoke via Hub1)

| Step | Source IP | Destination IP | Location |
|---|---|---|---|
| 1. Branch1-VM sends ping | `10.100.0.4` | `172.16.1.4` | Branch VNet |
| 2. Enters Hub1 VPN GW (IngressSnat) | **`203.0.113.4`** | `172.16.1.4` | Hub1 |
| 3. Routed through Azure Firewall | `203.0.113.4` | `172.16.1.4` | Hub1 |
| 4. Arrives at spoke1 VM | `203.0.113.4` | `172.16.1.4` | Spoke VNet |
| 5. Spoke1 VM replies | `172.16.1.4` | `203.0.113.4` | Spoke VNet |
| 6. Leaves Hub1 VPN GW (EgressSnat) | `172.16.1.4` | **`10.100.0.4`** | Hub1 |
| 7. Arrives at branch | `172.16.1.4` | `10.100.0.4` | Branch VNet |

---

## Prerequisites

- **PowerShell 7+** — Uses pwsh syntax. Install from [https://aka.ms/PSWindows](https://aka.ms/PSWindows)
- **Azure Subscription** with sufficient quota
- **RBAC Role** — Owner or Contributor at subscription level
- **Azure CLI** — Logged in with `az login`

> **Cost Warning:** This lab deploys Azure Firewall (Premium), VPN Gateways, and Bastion Standard — these have hourly costs. See [Cleanup](#cleanup) when done.

---

## Deployment

```powershell
# Clone and deploy
git clone <repo-url>
cd azure-vwan-vpn-nat-lab

# Deploy with defaults (203.0.113.0/24 for Hub1, 198.51.100.0/24 for Hub2)
.\deploy-bicep.ps1 -ResourceGroupName vwan-vpn-nat-lab -Location westus3

# Or customize the NAT ranges
.\deploy-bicep.ps1 `
    -ResourceGroupName vwan-vpn-nat-lab `
    -Location westus3 `
    -BranchInternalRange "10.100.0.0/24" `
    -Hub1NatExternalRange "203.0.113.0/24" `
    -Hub2NatExternalRange "198.51.100.0/24"
```

Deployment takes approximately **60–90 minutes** (VPN gateways are the bottleneck).

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `ResourceGroupName` | `vwan-vpn-nat-lab` | Resource group name |
| `Location` | `westus3` | Azure region |
| `AdminUsername` | `azureuser` | VM admin user |
| `AdminPassword` | *(prompted)* | VM admin password |
| `FirewallSku` | `Premium` | Azure Firewall SKU |
| `BranchInternalRange` | `10.100.0.0/24` | Branch subnet to NAT (pre-NAT) |
| `Hub1NatExternalRange` | `203.0.113.0/24` | Hub1 public NAT range (post-NAT) |
| `Hub2NatExternalRange` | `198.51.100.0/24` | Hub2 public NAT range (post-NAT) |

---

## What Gets Deployed

- **Virtual WAN** + two Secured Virtual Hubs
- **4 Spoke VNets** (2 per hub) with VMs
- **1 Branch VNet** with VPN Gateway (BGP ASN 65010)
- **2 Hub VPN Gateways** with:
  - `enableBgpRouteTranslation: true`
  - IngressSnat + EgressSnat NAT rules per branch connection
- **2 Azure Firewalls** (Hub SKU) with Routing Intent (InternetAndPrivate)
- **Azure Bastion** (Standard, IP-based connections)
- **5 Ubuntu VMs** with traceroute pre-installed
- **Log Analytics** + Firewall diagnostic settings

### VM Network Information

| VM Name | VNet | Actual IP Range | Appears as (Hub1) | Appears as (Hub2) |
|---------|------|-----------------|--------------------|--------------------|
| branch1-vm | branch1 | 10.100.0.0/24 | 203.0.113.0/24 | 198.51.100.0/24 |
| hub1-spoke1-vm | hub1-spoke1 | 172.16.1.0/27 | *(no NAT)* | *(no NAT)* |
| hub1-spoke2-vm | hub1-spoke2 | 172.16.2.0/27 | *(no NAT)* | *(no NAT)* |
| hub2-spoke1-vm | hub2-spoke1 | 172.16.3.0/27 | *(no NAT)* | *(no NAT)* |
| hub2-spoke2-vm | hub2-spoke2 | 172.16.4.0/27 | *(no NAT)* | *(no NAT)* |

---

## Verifying NAT is Working

### 1. Check Effective Routes (Azure Portal)

1. Navigate to **Virtual Hub → Effective Routes**
2. You should see:
   - `203.0.113.0/24` with Next Hop = `VPN_S2S_Gateway` (Hub1)
   - `198.51.100.0/24` with Next Hop = `VPN_S2S_Gateway` (Hub2)
   - **NOT** `10.100.0.0/24` — the pre-NAT range should not appear

### 2. Check NAT Rules (Azure Portal)

1. Navigate to **Virtual Hub → VPN (Site to site) → NAT rules (Edit)**
2. You should see:
   - `IngressSnat-Branch1`: Internal `10.100.0.0/24` → External `203.0.113.0/24`
   - `EgressSnat-Branch1`: Internal `10.100.0.0/24` → External `203.0.113.0/24`

### 3. Verify with tcpdump (Live Traffic)

```bash
# Step 1: SSH to hub1-spoke1-vm via Bastion (IP: 172.16.1.4)
# Start packet capture
sudo tcpdump -i eth0 icmp -n

# Step 2: In a separate Bastion session, SSH to branch1-vm (IP: 10.100.0.4)
# Ping the spoke
ping 172.16.1.4

# Step 3: On the spoke's tcpdump output, you should see:
#   203.0.113.4 > 172.16.1.4: ICMP echo request
#   172.16.1.4 > 203.0.113.4: ICMP echo reply
#
# The source is 203.0.113.4 (NATted), NOT 10.100.0.4 (original)
```

### 4. Check VM's Effective Routes

```bash
# On hub1-spoke1-vm:
# In Azure Portal → VM → Networking → Effective Routes
# You should see a route for 203.0.113.0/24 (not 10.100.0.0/24)
```

### 5. Check Azure Firewall Logs

```kql
// In Log Analytics, query the firewall network rule log
AzureDiagnostics
| where Category == "AzureFirewallNetworkRule"
| where msg_s contains "203.0.113"
| project TimeGenerated, msg_s
| order by TimeGenerated desc
```

The firewall logs will show the NATted source IP (`203.0.113.x`), confirming NAT occurs before firewall inspection.

---

## Key Bicep Resources (NAT-specific)

The NAT configuration lives in [modules/vpn.bicep](modules/vpn.bicep):

```bicep
// NAT rules defined as child resources of the VPN gateway
resource hub1IngressNat 'Microsoft.Network/vpnGateways/natRules@2023-11-01' = {
  parent: hub1VpnGw
  name: 'IngressSnat-Branch1'
  properties: {
    type: 'Static'
    mode: 'IngressSnat'
    internalMappings: [{ addressSpace: '10.100.0.0/24' }]    // Pre-NAT (branch actual)
    externalMappings: [{ addressSpace: '203.0.113.0/24' }]    // Post-NAT (public range)
  }
}

// NAT rules referenced on the VPN connection's link
resource hub1BranchConn 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hub1VpnGw
  name: 'site-branch1-conn'
  properties: {
    vpnLinkConnections: [{
      properties: {
        ingressNatRules: [{ id: hub1IngressNat.id }]
        egressNatRules:  [{ id: hub1EgressNat.id }]
      }
    }]
  }
}
```

---

## Accessing VMs via Azure Bastion

Same as the base lab — use **IP-based connection** via Bastion Standard:

1. Navigate to **Azure Portal → Bastions → SharedBastion**
2. Select **Connect via IP address**
3. Enter the private IP of the target VM
4. Username: `azureuser`, password: as set during deployment

> **Routing Intent Note:** The Bastion VNet connection has `enableInternetSecurity: false` to allow Bastion control-plane connectivity.

---

## Cleanup

```powershell
az group delete -n vwan-vpn-nat-lab --yes --no-wait
```

---

## References

- [Configure NAT rules for your Virtual WAN VPN gateway](https://learn.microsoft.com/en-us/azure/virtual-wan/nat-rules-vpn-gateway) — The primary doc this lab implements
- [RFC 5737 — IPv4 Address Blocks Reserved for Documentation](https://datatracker.ietf.org/doc/html/rfc5737) — Why we use 203.0.113.0/24 and 198.51.100.0/24
- [Virtual WAN Site-to-Site VPN](https://learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-site-to-site-portal)
- [Routing Intent and Policies](https://learn.microsoft.com/en-us/azure/virtual-wan/how-to-routing-policies)

## Credits

Based on [azure-vwan-secure-hub-lab](https://github.com/colinweiner111/azure-vwan-secure-hub-lab), itself adapted from Daniel Mauser's [azure-virtualwan](https://github.com/dmauser/azure-virtualwan) work.

---

MIT Licensed.
