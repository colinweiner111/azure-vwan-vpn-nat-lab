# Azure Virtual WAN VPN NAT Lab - Two-Phase Deployment
#
# Phase 1: Bicep deploys all infrastructure (vWAN, hubs, gateways, NAT, VMs,
#           firewalls, bastion). Hub connections are created WITHOUT APIPA.
#
# Phase 2: (Only when UseApipaBgp=$true) REST API updates:
#           a) Set APIPA customBgpIpAddresses on hub VPN gateways
#           b) Update hub connections with vpnGatewayCustomBgpAddresses
#
# This two-phase approach is required because vWAN VPN gateways silently
# ignore customBgpIpAddresses during initial ARM/Bicep creation. APIPA can
# only be set via REST API PUT on an already-provisioned gateway.

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "vwan-vpn-nat-lab",

    [Parameter(Mandatory=$false)]
    [string]$Location = "westus3",

    [Parameter(Mandatory=$false)]
    [string]$AdminUsername = "azureuser",

    [Parameter(Mandatory=$false)]
    [string]$AdminPassword,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Standard', 'Premium')]
    [string]$FirewallSku = "Premium",

    [Parameter(Mandatory=$false)]
    [string]$BranchInternalRange = "10.100.0.0/24",

    [Parameter(Mandatory=$false)]
    [string]$Hub1NatExternalRange = "203.0.113.0/24",

    [Parameter(Mandatory=$false)]
    [string]$Hub2NatExternalRange = "198.51.100.0/24",

    [Parameter(Mandatory=$false)]
    [ValidateSet('Static', 'Dynamic')]
    [string]$NatType = "Static",

    [Parameter(Mandatory=$false)]
    [bool]$UseApipaBgp = $false,

    # APIPA addresses (only used when UseApipaBgp=$true)
    [string]$BranchApipaBgpIp    = "169.254.21.2",
    [string]$Hub1ApipaInstance0   = "169.254.21.1",
    [string]$Hub1ApipaInstance1   = "169.254.22.1",
    [string]$Hub2ApipaInstance0   = "169.254.21.5",
    [string]$Hub2ApipaInstance1   = "169.254.22.5"
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Wait for a resource to reach provisioningState "Succeeded"
# ─────────────────────────────────────────────────────────────────────────────
function Wait-ResourceReady {
    param(
        [string]$ResourceUri,
        [string]$ApiVersion,
        [string]$DisplayName,
        [int]$TimeoutMinutes = 20,
        [int]$PollIntervalSeconds = 30
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $res = az rest --method GET --uri "${ResourceUri}?api-version=${ApiVersion}" 2>$null | ConvertFrom-Json
        $state = $res.properties.provisioningState
        Write-Host "  [$DisplayName] provisioningState: $state" -ForegroundColor Gray
        if ($state -eq "Succeeded") { return $true }
        if ($state -eq "Failed")    { Write-Host "  [$DisplayName] FAILED!" -ForegroundColor Red; return $false }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    Write-Host "  [$DisplayName] TIMED OUT after $TimeoutMinutes minutes" -ForegroundColor Red
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "Checking Azure login..." -ForegroundColor Cyan
$account = az account show 2>$null | ConvertFrom-Json
if (!$account) {
    Write-Host "Not logged in. Please login to Azure..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}
$subscriptionId = $account.id
Write-Host "Using subscription: $($account.name) ($subscriptionId)" -ForegroundColor Green

if (-not $AdminPassword) {
    $SecurePassword = Read-Host -Prompt "Enter VM admin password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Deployment Parameters                                      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Location:       $Location"
Write-Host "  Firewall SKU:   $FirewallSku"
Write-Host ""
Write-Host "  VPN NAT:" -ForegroundColor Yellow
Write-Host "    Branch Internal:    $BranchInternalRange"
Write-Host "    Hub1 External:      $Hub1NatExternalRange  (TEST-NET-3)"
Write-Host "    Hub2 External:      $Hub2NatExternalRange  (TEST-NET-2)"
Write-Host "    NAT Type:           $NatType"
Write-Host ""
Write-Host "  BGP:" -ForegroundColor Yellow
if ($UseApipaBgp) {
    Write-Host "    Mode:               APIPA (169.254.x.x)"
    Write-Host "    Branch:             $BranchApipaBgpIp"
    Write-Host "    Hub1 Instance0/1:   $Hub1ApipaInstance0 / $Hub1ApipaInstance1"
    Write-Host "    Hub2 Instance0/1:   $Hub2ApipaInstance0 / $Hub2ApipaInstance1"
} else {
    Write-Host "    Mode:               Default hub IPs"
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1: Bicep Deployment
# ═════════════════════════════════════════════════════════════════════════════
Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  PHASE 1: Bicep Deployment                                  ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "Deploying all infrastructure (60-90 minutes)..." -ForegroundColor Yellow
Write-Host "  - Virtual WAN with 2 secure hubs"
Write-Host "  - 6 Virtual Networks + 5 Ubuntu VMs"
Write-Host "  - Branch VPN Gateway + 2 Hub VPN Gateways"
Write-Host "  - VPN NAT Rules ($NatType IngressSnat per hub)"
Write-Host "  - Hub connections (without APIPA — added in Phase 2)"
Write-Host "  - 2 Azure Firewalls ($FirewallSku) + Routing Intent"
Write-Host "  - Azure Bastion with IP-based connections"

$deploymentName = "vwan-vpn-nat-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file "$PSScriptRoot\main.bicep" `
    --parameters resourceGroupName=$ResourceGroupName `
                 region1=$Location `
                 region2=$Location `
                 adminUsername=$AdminUsername `
                 adminPassword=$AdminPassword `
                 firewallSku=$FirewallSku `
                 branchInternalRange=$BranchInternalRange `
                 hub1NatExternalRange=$Hub1NatExternalRange `
                 hub2NatExternalRange=$Hub2NatExternalRange `
                 natType=$NatType `
                 useApipaBgp=false `
                 branchApipaBgpIp=$BranchApipaBgpIp `
                 hub1ApipaInstance0=$Hub1ApipaInstance0 `
                 hub1ApipaInstance1=$Hub1ApipaInstance1 `
                 hub2ApipaInstance0=$Hub2ApipaInstance0 `
                 hub2ApipaInstance1=$Hub2ApipaInstance1

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nPhase 1 FAILED. Check deployment errors above." -ForegroundColor Red
    exit 1
}

Write-Host "`nPhase 1 COMPLETE — all Bicep resources deployed." -ForegroundColor Green

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2: REST API — Set APIPA on Hub VPN Gateways + Update Connections
# ═════════════════════════════════════════════════════════════════════════════
if (-not $UseApipaBgp) {
    Write-Host "`nAPIPIA BGP disabled — skipping Phase 2." -ForegroundColor Gray
    Write-Host "`n✓ Deployment complete!" -ForegroundColor Green
}
else {
    Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║  PHASE 2: REST API — APIPA BGP on Hub Gateways             ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host "vWAN VPN gateways ignore APIPA during ARM creation." -ForegroundColor Yellow
    Write-Host "Setting APIPA via REST API PUT on provisioned gateways..." -ForegroundColor Yellow

    # Resource IDs
    $hub1GwUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/vpnGateways/hub1-vpngw"
    $hub2GwUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/vpnGateways/hub2-vpngw"
    $hub1ConnUri = "$hub1GwUri/vpnConnections/site-branch1-conn"
    $hub2ConnUri = "$hub2GwUri/vpnConnections/site-branch1-conn"
    $hub1Id = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualHubs/hub1"
    $hub2Id = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualHubs/hub2"
    $apiVersion = "2023-11-01"

    # ── Step 2a: GET current hub gateways to capture existing properties ─────
    Write-Host "`n[Step 2a] Reading current hub gateway configurations..." -ForegroundColor Cyan

    $hub1Gw = az rest --method GET --uri "${hub1GwUri}?api-version=${apiVersion}" | ConvertFrom-Json
    $hub2Gw = az rest --method GET --uri "${hub2GwUri}?api-version=${apiVersion}" | ConvertFrom-Json

    Write-Host "  Hub1 gateway state: $($hub1Gw.properties.provisioningState)" -ForegroundColor Gray
    Write-Host "  Hub2 gateway state: $($hub2Gw.properties.provisioningState)" -ForegroundColor Gray

    # ── Step 2b: PUT APIPA on Hub1 gateway ───────────────────────────────────
    Write-Host "`n[Step 2b] Setting APIPA BGP on hub1-vpngw..." -ForegroundColor Cyan

    # Merge APIPA into the full gateway object from Step 2a to preserve connections & NAT rules
    $hub1Gw.properties.bgpSettings.bgpPeeringAddresses = @(
        @{ ipconfigurationId = "Instance0"; customBgpIpAddresses = @($Hub1ApipaInstance0) }
        @{ ipconfigurationId = "Instance1"; customBgpIpAddresses = @($Hub1ApipaInstance1) }
    )
    $hub1Gw.properties.enableBgpRouteTranslationForNat = $true
    $hub1GwBody = @{
        location = $hub1Gw.location
        properties = $hub1Gw.properties
        tags = $hub1Gw.tags
    } | ConvertTo-Json -Depth 20 -Compress

    $tempFile1 = [System.IO.Path]::GetTempFileName()
    $hub1GwBody | Out-File -FilePath $tempFile1 -Encoding utf8

    az rest --method PUT --uri "${hub1GwUri}?api-version=${apiVersion}" --body "@$tempFile1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED to PUT APIPA on hub1-vpngw" -ForegroundColor Red
        Remove-Item $tempFile1 -ErrorAction SilentlyContinue
        exit 1
    }
    Remove-Item $tempFile1 -ErrorAction SilentlyContinue

    # Wait for hub1 gateway
    Write-Host "  Waiting for hub1-vpngw to reach Succeeded..." -ForegroundColor Gray
    $ok = Wait-ResourceReady -ResourceUri $hub1GwUri -ApiVersion $apiVersion -DisplayName "hub1-vpngw"
    if (-not $ok) { Write-Host "hub1-vpngw did not reach Succeeded. Aborting." -ForegroundColor Red; exit 1 }

    # ── Step 2c: PUT APIPA on Hub2 gateway ───────────────────────────────────
    Write-Host "`n[Step 2c] Setting APIPA BGP on hub2-vpngw..." -ForegroundColor Cyan

    # Merge APIPA into the full gateway object from Step 2a to preserve connections & NAT rules
    $hub2Gw.properties.bgpSettings.bgpPeeringAddresses = @(
        @{ ipconfigurationId = "Instance0"; customBgpIpAddresses = @($Hub2ApipaInstance0) }
        @{ ipconfigurationId = "Instance1"; customBgpIpAddresses = @($Hub2ApipaInstance1) }
    )
    $hub2Gw.properties.enableBgpRouteTranslationForNat = $true
    $hub2GwBody = @{
        location = $hub2Gw.location
        properties = $hub2Gw.properties
        tags = $hub2Gw.tags
    } | ConvertTo-Json -Depth 20 -Compress

    $tempFile2 = [System.IO.Path]::GetTempFileName()
    $hub2GwBody | Out-File -FilePath $tempFile2 -Encoding utf8

    az rest --method PUT --uri "${hub2GwUri}?api-version=${apiVersion}" --body "@$tempFile2"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED to PUT APIPA on hub2-vpngw" -ForegroundColor Red
        Remove-Item $tempFile2 -ErrorAction SilentlyContinue
        exit 1
    }
    Remove-Item $tempFile2 -ErrorAction SilentlyContinue

    # Wait for hub2 gateway
    Write-Host "  Waiting for hub2-vpngw to reach Succeeded..." -ForegroundColor Gray
    $ok = Wait-ResourceReady -ResourceUri $hub2GwUri -ApiVersion $apiVersion -DisplayName "hub2-vpngw"
    if (-not $ok) { Write-Host "hub2-vpngw did not reach Succeeded. Aborting." -ForegroundColor Red; exit 1 }

    Write-Host "`n  Both hub gateways now have APIPA BGP addresses." -ForegroundColor Green

    # ── Step 2d: GET existing connections and add vpnGatewayCustomBgpAddresses ──
    Write-Host "`n[Step 2d] Updating hub connections with APIPA BGP addresses..." -ForegroundColor Cyan

    # --- Hub1 Connection ---
    Write-Host "  Updating hub1 connection..." -ForegroundColor Cyan
    $hub1Conn = az rest --method GET --uri "${hub1ConnUri}?api-version=${apiVersion}" | ConvertFrom-Json

    # Get the NAT rule ID from existing connection
    $hub1NatRuleId = $hub1Conn.properties.vpnLinkConnections[0].properties.ingressNatRules[0].id
    $vpnSiteId = $hub1Conn.properties.remoteVpnSite.id
    $hub1SiteLinkId = $hub1Conn.properties.vpnLinkConnections[0].properties.vpnSiteLink.id

    $hub1ConnBody = @{
        properties = @{
            remoteVpnSite = @{ id = $vpnSiteId }
            enableInternetSecurity = $true
            vpnLinkConnections = @(
                @{
                    name = "link1"
                    properties = @{
                        vpnSiteLink = @{ id = $hub1SiteLinkId }
                        sharedKey = "abc123"
                        enableBgp = $true
                        vpnGatewayCustomBgpAddresses = @(
                            @{ ipConfigurationId = "Instance0"; customBgpIpAddress = $Hub1ApipaInstance0 }
                            @{ ipConfigurationId = "Instance1"; customBgpIpAddress = $Hub1ApipaInstance1 }
                        )
                        ingressNatRules = @(
                            @{ id = $hub1NatRuleId }
                        )
                    }
                }
            )
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $tempFile3 = [System.IO.Path]::GetTempFileName()
    $hub1ConnBody | Out-File -FilePath $tempFile3 -Encoding utf8

    az rest --method PUT --uri "${hub1ConnUri}?api-version=${apiVersion}" --body "@$tempFile3"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED to update hub1 connection with APIPA" -ForegroundColor Red
        Remove-Item $tempFile3 -ErrorAction SilentlyContinue
        exit 1
    }
    Remove-Item $tempFile3 -ErrorAction SilentlyContinue

    # Wait for hub1 gateway (connection update triggers gateway update)
    Write-Host "  Waiting for hub1-vpngw to settle after connection update..." -ForegroundColor Gray
    $ok = Wait-ResourceReady -ResourceUri $hub1GwUri -ApiVersion $apiVersion -DisplayName "hub1-vpngw"
    if (-not $ok) { Write-Host "hub1 connection update did not succeed. Aborting." -ForegroundColor Red; exit 1 }

    # --- Hub2 Connection ---
    Write-Host "  Updating hub2 connection..." -ForegroundColor Cyan
    $hub2Conn = az rest --method GET --uri "${hub2ConnUri}?api-version=${apiVersion}" | ConvertFrom-Json

    $hub2NatRuleId = $hub2Conn.properties.vpnLinkConnections[0].properties.ingressNatRules[0].id
    $hub2SiteLinkId = $hub2Conn.properties.vpnLinkConnections[0].properties.vpnSiteLink.id

    $hub2ConnBody = @{
        properties = @{
            remoteVpnSite = @{ id = $vpnSiteId }
            enableInternetSecurity = $true
            vpnLinkConnections = @(
                @{
                    name = "link1"
                    properties = @{
                        vpnSiteLink = @{ id = $hub2SiteLinkId }
                        sharedKey = "abc123"
                        enableBgp = $true
                        vpnGatewayCustomBgpAddresses = @(
                            @{ ipConfigurationId = "Instance0"; customBgpIpAddress = $Hub2ApipaInstance0 }
                            @{ ipConfigurationId = "Instance1"; customBgpIpAddress = $Hub2ApipaInstance1 }
                        )
                        ingressNatRules = @(
                            @{ id = $hub2NatRuleId }
                        )
                    }
                }
            )
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $tempFile4 = [System.IO.Path]::GetTempFileName()
    $hub2ConnBody | Out-File -FilePath $tempFile4 -Encoding utf8

    az rest --method PUT --uri "${hub2ConnUri}?api-version=${apiVersion}" --body "@$tempFile4"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED to update hub2 connection with APIPA" -ForegroundColor Red
        Remove-Item $tempFile4 -ErrorAction SilentlyContinue
        exit 1
    }
    Remove-Item $tempFile4 -ErrorAction SilentlyContinue

    # Wait for hub2 gateway
    Write-Host "  Waiting for hub2-vpngw to settle after connection update..." -ForegroundColor Gray
    $ok = Wait-ResourceReady -ResourceUri $hub2GwUri -ApiVersion $apiVersion -DisplayName "hub2-vpngw"
    if (-not $ok) { Write-Host "hub2 connection update did not succeed. Aborting." -ForegroundColor Red; exit 1 }

    Write-Host "`n  Phase 2 COMPLETE — APIPA BGP configured on hub gateways and connections." -ForegroundColor Green
}

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  DEPLOYMENT COMPLETE                                        ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`nVPN NAT Translation:" -ForegroundColor Yellow
Write-Host "  NAT Type:  $NatType"
Write-Host "  Hub1:      $BranchInternalRange  -->  $Hub1NatExternalRange"
Write-Host "  Hub2:      $BranchInternalRange  -->  $Hub2NatExternalRange"
if ($UseApipaBgp) {
    Write-Host "`nAPIP BGP Peering:" -ForegroundColor Yellow
    Write-Host "  Branch:           $BranchApipaBgpIp  (ASN 65010)"
    Write-Host "  Hub1 Instance0:   $Hub1ApipaInstance0  (ASN 65515)"
    Write-Host "  Hub1 Instance1:   $Hub1ApipaInstance1  (ASN 65515)"
    Write-Host "  Hub2 Instance0:   $Hub2ApipaInstance0  (ASN 65515)"
    Write-Host "  Hub2 Instance1:   $Hub2ApipaInstance1  (ASN 65515)"
}

Write-Host "`nNext Steps:" -ForegroundColor Yellow
Write-Host "  1. Open Azure Portal > Bastion (IP-Based Connection)"
Write-Host "  2. Test VM connectivity:"
Write-Host "       branch1VM:       10.100.0.4"
Write-Host "       hub1-spoke1-vm:  172.16.1.4"
Write-Host "       hub1-spoke2-vm:  172.16.2.4"
Write-Host "       hub2-spoke1-vm:  172.16.3.4"
Write-Host "       hub2-spoke2-vm:  172.16.4.4"
Write-Host "`n  3. Verify NAT: On spoke VM run  sudo tcpdump -i eth0 icmp"
Write-Host "     then from branch1VM:  ping 172.16.1.4"
Write-Host "     tcpdump should show source IP as 203.0.113.x (NOT 10.100.0.x)"
Write-Host "`n  4. Check effective routes in Virtual Hub > Effective Routes"
Write-Host "     Should show $Hub1NatExternalRange via VPN_S2S_Gateway"

# Cleanup
$AdminPassword = $null
[System.GC]::Collect()
