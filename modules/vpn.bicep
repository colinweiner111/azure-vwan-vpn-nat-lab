param location string
param vwanName string
param hub1Name string
param hub2Name string
param branchVnetId string
param hub1Id string
param hub2Id string

@description('Branch internal address range to NAT')
param branchInternalRange string

@description('Public IP range for Hub1 NAT translation')
param hub1NatExternalRange string

@description('Public IP range for Hub2 NAT translation')
param hub2NatExternalRange string

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Branch VPN Gateway                                                        ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource branchPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'branch1-vpngw-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource branchVpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = {
  name: 'branch1-vpngw'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    enableBgp: true
    bgpSettings: {
      asn: 65010
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${branchVnetId}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: branchPublicIp.id
          }
        }
      }
    ]
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Hub VPN Gateways (with BGP Route Translation for NAT)                     ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource hub1VpnGw 'Microsoft.Network/vpnGateways@2023-11-01' = {
  name: '${hub1Name}-vpngw'
  location: location
  properties: {
    virtualHub: {
      id: hub1Id
    }
    bgpSettings: {
      asn: 65515
    }
    enableBgpRouteTranslation: true
  }
}

resource hub2VpnGw 'Microsoft.Network/vpnGateways@2023-11-01' = {
  name: '${hub2Name}-vpngw'
  location: location
  properties: {
    virtualHub: {
      id: hub2Id
    }
    bgpSettings: {
      asn: 65515
    }
    enableBgpRouteTranslation: true
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  VPN NAT Rules — Hub1                                                      ║
// ║                                                                            ║
// ║  IngressSnat: Branch → Hub traffic. Source IP translated from private to    ║
// ║               public range so spokes see branch as 203.0.113.0/24.         ║
// ║                                                                            ║
// ║  EgressSnat:  Hub → Branch traffic. Destination IP translated from public   ║
// ║               range back to private so branch receives return traffic.      ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource hub1IngressNat 'Microsoft.Network/vpnGateways/natRules@2023-11-01' = {
  parent: hub1VpnGw
  name: 'IngressSnat-Branch1'
  properties: {
    type: 'Static'
    mode: 'IngressSnat'
    internalMappings: [
      {
        addressSpace: branchInternalRange
      }
    ]
    externalMappings: [
      {
        addressSpace: hub1NatExternalRange
      }
    ]
  }
}

resource hub1EgressNat 'Microsoft.Network/vpnGateways/natRules@2023-11-01' = {
  parent: hub1VpnGw
  name: 'EgressSnat-Branch1'
  properties: {
    type: 'Static'
    mode: 'EgressSnat'
    internalMappings: [
      {
        addressSpace: branchInternalRange
      }
    ]
    externalMappings: [
      {
        addressSpace: hub1NatExternalRange
      }
    ]
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  VPN NAT Rules — Hub2                                                      ║
// ║                                                                            ║
// ║  Same pattern as Hub1 but maps to a different public range                 ║
// ║  (198.51.100.0/24) demonstrating per-hub NAT independence.                 ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource hub2IngressNat 'Microsoft.Network/vpnGateways/natRules@2023-11-01' = {
  parent: hub2VpnGw
  name: 'IngressSnat-Branch1'
  properties: {
    type: 'Static'
    mode: 'IngressSnat'
    internalMappings: [
      {
        addressSpace: branchInternalRange
      }
    ]
    externalMappings: [
      {
        addressSpace: hub2NatExternalRange
      }
    ]
  }
}

resource hub2EgressNat 'Microsoft.Network/vpnGateways/natRules@2023-11-01' = {
  parent: hub2VpnGw
  name: 'EgressSnat-Branch1'
  properties: {
    type: 'Static'
    mode: 'EgressSnat'
    internalMappings: [
      {
        addressSpace: branchInternalRange
      }
    ]
    externalMappings: [
      {
        addressSpace: hub2NatExternalRange
      }
    ]
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  VPN Site for Branch1                                                      ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource vpnSite 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'site-branch1'
  location: location
  dependsOn: [
    branchVpnGateway
  ]
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'Microsoft'
      deviceModel: 'Azure'
      linkSpeedInMbps: 50
    }
    vpnSiteLinks: [
      {
        name: 'link1'
        properties: {
          ipAddress: branchPublicIp.properties.ipAddress
          bgpProperties: {
            asn: 65010
            bgpPeeringAddress: branchVpnGateway.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
          }
          linkProperties: {
            linkSpeedInMbps: 50
          }
        }
      }
    ]
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Hub → Branch VPN Connections (with NAT rules attached)                    ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource hub1BranchConn 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hub1VpnGw
  name: 'site-branch1-conn'
  properties: {
    remoteVpnSite: {
      id: vpnSite.id
    }
    enableInternetSecurity: true
    vpnLinkConnections: [
      {
        name: 'link1'
        properties: {
          vpnSiteLink: {
            id: '${vpnSite.id}/vpnSiteLinks/link1'
          }
          sharedKey: 'abc123'
          enableBgp: true
          ingressNatRules: [
            {
              id: hub1IngressNat.id
            }
          ]
          egressNatRules: [
            {
              id: hub1EgressNat.id
            }
          ]
        }
      }
    ]
  }
  dependsOn: [
    hub1IngressNat
    hub1EgressNat
  ]
}

resource hub2BranchConn 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hub2VpnGw
  name: 'site-branch1-conn'
  properties: {
    remoteVpnSite: {
      id: vpnSite.id
    }
    enableInternetSecurity: true
    vpnLinkConnections: [
      {
        name: 'link1'
        properties: {
          vpnSiteLink: {
            id: '${vpnSite.id}/vpnSiteLinks/link1'
          }
          sharedKey: 'abc123'
          enableBgp: true
          ingressNatRules: [
            {
              id: hub2IngressNat.id
            }
          ]
          egressNatRules: [
            {
              id: hub2EgressNat.id
            }
          ]
        }
      }
    ]
  }
  dependsOn: [
    hub2IngressNat
    hub2EgressNat
  ]
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Local Network Gateways + Branch-side VPN Connections                      ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

// Local Gateways for Hub1
resource lngHub1Gw1 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-${hub1Name}-gw1'
  location: location
  properties: {
    gatewayIpAddress: hub1VpnGw.properties.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hub1VpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
    }
  }
}

resource lngHub1Gw2 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-${hub1Name}-gw2'
  location: location
  properties: {
    gatewayIpAddress: hub1VpnGw.properties.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hub1VpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
    }
  }
}

// Local Gateways for Hub2
resource lngHub2Gw1 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-${hub2Name}-gw1'
  location: location
  properties: {
    gatewayIpAddress: hub2VpnGw.properties.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hub2VpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
    }
  }
}

resource lngHub2Gw2 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-${hub2Name}-gw2'
  location: location
  properties: {
    gatewayIpAddress: hub2VpnGw.properties.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hub2VpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
    }
  }
}

// VPN Connections from Branch to Hubs
resource branchToHub1Gw1Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-to-${hub1Name}-gw1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branchVpnGateway.id
    }
    localNetworkGateway2: {
      id: lngHub1Gw1.id
    }
    sharedKey: 'abc123'
    enableBgp: true
  }
}

resource branchToHub1Gw2Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-to-${hub1Name}-gw2'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branchVpnGateway.id
    }
    localNetworkGateway2: {
      id: lngHub1Gw2.id
    }
    sharedKey: 'abc123'
    enableBgp: true
  }
}

resource branchToHub2Gw1Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-to-${hub2Name}-gw1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branchVpnGateway.id
    }
    localNetworkGateway2: {
      id: lngHub2Gw1.id
    }
    sharedKey: 'abc123'
    enableBgp: true
  }
}

resource branchToHub2Gw2Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-to-${hub2Name}-gw2'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branchVpnGateway.id
    }
    localNetworkGateway2: {
      id: lngHub2Gw2.id
    }
    sharedKey: 'abc123'
    enableBgp: true
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Outputs                                                                   ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

output branchVpnGatewayId string = branchVpnGateway.id
output hub1VpnGwId string = hub1VpnGw.id
output hub2VpnGwId string = hub2VpnGw.id
output vpnSiteId string = vpnSite.id
output hub1IngressNatId string = hub1IngressNat.id
output hub1EgressNatId string = hub1EgressNat.id
output hub2IngressNatId string = hub2IngressNat.id
output hub2EgressNatId string = hub2EgressNat.id
