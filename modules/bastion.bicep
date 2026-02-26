param location string
param hub1Name string

// Bastion NSG
resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'bastion-nsg'
  location: location
  properties: {
    securityRules: [
      // Inbound rules
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      // Outbound rules
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowGetSessionInformation'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
    ]
  }
}

// Reference existing Bastion VNET
resource bastionVnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: 'bastion-vnet'
}

// Attach NSG to AzureBastionSubnet
resource bastionSubnetNsgAttachment 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: bastionVnet
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: '10.200.0.0/26'
    networkSecurityGroup: {
      id: bastionNsg.id
    }
  }
}

// Bastion Public IP
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'Bastion-PIP'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Azure Bastion Host
resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: 'SharedBastion'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    enableIpConnect: true
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: bastionSubnetNsgAttachment.id
          }
          publicIPAddress: {
            id: bastionPip.id
          }
        }
      }
    ]
  }
}

// Bastion VNET connection to Hub1 WITHOUT internet security
resource bastionHubConnection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  name: '${hub1Name}/bastion-vnet-conn'
  properties: {
    remoteVirtualNetwork: {
      id: bastionVnet.id
    }
    enableInternetSecurity: false
  }
  dependsOn: [
    bastion
  ]
}

output bastionId string = bastion.id
output bastionName string = bastion.name
output bastionNsgId string = bastionNsg.id
