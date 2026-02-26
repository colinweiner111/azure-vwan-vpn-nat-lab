# Azure Virtual WAN VPN NAT Lab - Bicep Deployment
# This script deploys a Virtual WAN lab with VPN S2S NAT rules
# translating branch private ranges to public IP ranges.

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
    [string]$Hub2NatExternalRange = "198.51.100.0/24"
)

# Check if logged into Azure
Write-Host "Checking Azure login..." -ForegroundColor Cyan
$account = az account show 2>$null | ConvertFrom-Json
if (!$account) {
    Write-Host "Not logged in. Please login to Azure..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}

Write-Host "Using subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# Prompt for password if not provided
if (-not $AdminPassword) {
    $SecurePassword = Read-Host -Prompt "Enter VM admin password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

Write-Host "`nDeployment Parameters:" -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Location: $Location"
Write-Host "  Admin Username: $AdminUsername"
Write-Host "  Firewall SKU: $FirewallSku"
Write-Host ""
Write-Host "  VPN NAT Configuration:" -ForegroundColor Yellow
Write-Host "    Branch Internal Range:    $BranchInternalRange"
Write-Host "    Hub1 NAT External Range:  $Hub1NatExternalRange  (RFC 5737 TEST-NET-3)"
Write-Host "    Hub2 NAT External Range:  $Hub2NatExternalRange  (RFC 5737 TEST-NET-2)"

Write-Host "`nStarting Bicep deployment (this will take approximately 60-90 minutes)..." -ForegroundColor Yellow
Write-Host "Components to deploy:" -ForegroundColor Cyan
Write-Host "  - Virtual WAN with 2 secure hubs"
Write-Host "  - 6 Virtual Networks (Branch, Bastion, 4 Spokes)"
Write-Host "  - 5 Ubuntu VMs"
Write-Host "  - Branch VPN Gateway + 2 Hub VPN Gateways"
Write-Host "  - VPN NAT Rules (IngressSnat + EgressSnat per hub)"
Write-Host "  - 2 Azure Firewalls ($FirewallSku) with InternetAndPrivate routing"
Write-Host "  - Azure Bastion with IP-based connection"

$deploymentName = "vwan-vpn-nat-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    # Deploy using Azure CLI + Bicep
    Write-Host "`nStarting deployment..." -ForegroundColor Cyan
    
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
                     hub2NatExternalRange=$Hub2NatExternalRange
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n======================================" -ForegroundColor Green
        Write-Host " Deployment completed successfully!" -ForegroundColor Green
        Write-Host "======================================" -ForegroundColor Green
        
        Write-Host "`nVPN NAT Translation Summary:" -ForegroundColor Yellow
        Write-Host "  Hub1: $BranchInternalRange --> $Hub1NatExternalRange"
        Write-Host "  Hub2: $BranchInternalRange --> $Hub2NatExternalRange"
        
        Write-Host "`nNext Steps:" -ForegroundColor Yellow
        Write-Host "1. Navigate to Azure Portal > Bastion"
        Write-Host "2. Connect to VMs using IP-based connection:"
        Write-Host "   - branch1VM: 10.100.0.4"
        Write-Host "   - hub1-spoke1-vm: 172.16.1.4"
        Write-Host "   - hub1-spoke2-vm: 172.16.2.4"
        Write-Host "   - hub2-spoke1-vm: 172.16.3.4"
        Write-Host "   - hub2-spoke2-vm: 172.16.4.4"
        Write-Host ""
        Write-Host "3. Verify NAT is working:" -ForegroundColor Cyan
        Write-Host "   a) SSH to hub1-spoke1-vm via Bastion (172.16.1.4)"
        Write-Host "   b) Start a listener:  sudo tcpdump -i eth0 icmp"
        Write-Host "   c) SSH to branch1-vm via Bastion (10.100.0.4)"
        Write-Host "   d) Ping the spoke:    ping 172.16.1.4"
        Write-Host "   e) On the spoke tcpdump output, you should see"
        Write-Host "      source IP as 203.0.113.x (NOT 10.100.0.x)"
        Write-Host ""
        Write-Host "4. Check effective routes in Azure Portal:" -ForegroundColor Cyan
        Write-Host "   Virtual Hub > Effective Routes should show"
        Write-Host "   $Hub1NatExternalRange via VPN_S2S_Gateway (not $BranchInternalRange)"
    }
    else {
        Write-Host "`n✗ Deployment failed" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "`n✗ Deployment error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    # Clear password from memory
    $AdminPassword = $null
    [System.GC]::Collect()
}
