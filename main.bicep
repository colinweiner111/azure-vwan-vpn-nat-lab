targetScope = 'subscription'

@description('Primary region for deployment')
param region1 string = 'westus3'

@description('Secondary region for deployment (same as primary for intra-region)')
param region2 string = 'westus3'

@description('Resource group name')
param resourceGroupName string = 'vwan-vpn-nat-lab'

@description('Virtual WAN name')
param vwanName string = 'vwan-demo'

@description('Hub 1 name')
param hub1Name string = 'hub1'

@description('Hub 2 name')
param hub2Name string = 'hub2'

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('Admin password for VMs')
@secure()
param adminPassword string

@description('VM size')
param vmSize string = 'Standard_DS1_v2'

@description('Azure Firewall SKU')
@allowed(['Standard', 'Premium'])
param firewallSku string = 'Premium'

// ─── VPN NAT Parameters ────────────────────────────────────────────────────────

@description('Branch internal address range to NAT (main subnet where VMs reside)')
param branchInternalRange string = '10.100.0.0/24'

@description('Public IP range for Hub1 branch NAT (RFC 5737 TEST-NET-3)')
param hub1NatExternalRange string = '203.0.113.0/24'

@description('Public IP range for Hub2 branch NAT (RFC 5737 TEST-NET-2)')
param hub2NatExternalRange string = '198.51.100.0/24'

@description('NAT rule type — Static (1:1 same-size prefix mapping) or Dynamic (many-to-few with port translation)')
@allowed(['Static', 'Dynamic'])
param natType string = 'Static'

@description('Use APIPA (169.254.x.x) addresses for BGP peering over VPN tunnels')
param useApipaBgp bool = true

@description('Branch APIPA BGP address')
param branchApipaBgpIp string = '169.254.21.2'

@description('Hub1 Instance0 APIPA BGP address')
param hub1ApipaInstance0 string = '169.254.21.1'

@description('Hub1 Instance1 APIPA BGP address')
param hub1ApipaInstance1 string = '169.254.22.1'

@description('Hub2 Instance0 APIPA BGP address')
param hub2ApipaInstance0 string = '169.254.21.5'

@description('Hub2 Instance1 APIPA BGP address')
param hub2ApipaInstance1 string = '169.254.22.5'

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: region1
}

// Network Infrastructure
module network 'modules/network.bicep' = {
  scope: rg
  name: 'network-deployment'
  params: {
    location: region1
    vwanName: vwanName
    hub1Name: hub1Name
    hub2Name: hub2Name
  }
}

// Virtual Machines
module vms 'modules/vms.bicep' = {
  scope: rg
  name: 'vms-deployment'
  params: {
    location: region1
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    hub1Name: hub1Name
    hub2Name: hub2Name
  }
  dependsOn: [
    network
  ]
}

// VPN Infrastructure + NAT Rules
module vpn 'modules/vpn.bicep' = {
  scope: rg
  name: 'vpn-deployment'
  params: {
    location: region1
    hub1Name: hub1Name
    hub2Name: hub2Name
    vwanName: vwanName
    branchVnetId: network.outputs.branchVnetId
    hub1Id: network.outputs.hub1Id
    hub2Id: network.outputs.hub2Id
    branchInternalRange: branchInternalRange
    hub1NatExternalRange: hub1NatExternalRange
    hub2NatExternalRange: hub2NatExternalRange
    natType: natType
    useApipaBgp: useApipaBgp
    branchApipaBgpIp: branchApipaBgpIp
    hub1ApipaInstance0: hub1ApipaInstance0
    hub1ApipaInstance1: hub1ApipaInstance1
    hub2ApipaInstance0: hub2ApipaInstance0
    hub2ApipaInstance1: hub2ApipaInstance1
  }
  dependsOn: [
    network
  ]
}

// Azure Firewall and Routing Intent
module firewall 'modules/firewall.bicep' = {
  scope: rg
  name: 'firewall-deployment'
  params: {
    location: region1
    hub1Name: hub1Name
    hub2Name: hub2Name
    firewallSku: firewallSku
  }
  dependsOn: [
    network
    vpn
  ]
}

// Azure Bastion
module bastion 'modules/bastion.bicep' = {
  scope: rg
  name: 'bastion-deployment'
  params: {
    location: region1
    hub1Name: hub1Name
  }
  dependsOn: [
    network
    firewall
  ]
}

output vwanId string = network.outputs.vwanId
output hub1Id string = network.outputs.hub1Id
output hub2Id string = network.outputs.hub2Id
output bastionName string = bastion.outputs.bastionName
output hub1NatRange string = hub1NatExternalRange
output hub2NatRange string = hub2NatExternalRange
output natType string = natType
output apipaBgpEnabled bool = useApipaBgp
