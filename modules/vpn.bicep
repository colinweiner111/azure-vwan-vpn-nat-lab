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

@description('NAT rule type — Static (1:1 same-size prefix mapping) or Dynamic (many-to-few with port translation)')
@allowed(['Static', 'Dynamic'])
param natType string = 'Static'

@description('Use APIPA (169.254.x.x) addresses for BGP peering over VPN tunnels')
param useApipaBgp bool = false

@description('Branch APIPA BGP address (used for all hub BGP sessions)')
param branchApipaBgpIp string = '169.254.21.2'

@description('Hub1 Instance0 APIPA BGP address')
param hub1ApipaInstance0 string = '169.254.21.1'

@description('Hub1 Instance1 APIPA BGP address')
param hub1ApipaInstance1 string = '169.254.22.1'

@description('Hub2 Instance0 APIPA BGP address')
param hub2ApipaInstance0 string = '169.254.21.5'

@description('Hub2 Instance1 APIPA BGP address')
param hub2ApipaInstance1 string = '169.254.22.5'

@description('Enable EgressSnat on Hub1 to NAT spoke addresses toward the branch')
param enableHub1EgressSnat bool = false

@description('Spoke internal range for Hub1 EgressSnat (actual spoke CIDR)')
param hub1EgressInternalRange string = '172.16.2.0/26'

@description('Spoke external range for Hub1 EgressSnat (what the branch sees)')
param hub1EgressExternalRange string = '203.0.113.0/26'

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Variables                                                                 ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

var branchGwName = 'branch1-vpngw'

// Construct the branch gateway IP config resource ID for APIPA BGP references
var branchGwIpConfigId = resourceId('Microsoft.Network/virtualNetworkGateways/ipConfigurations', branchGwName, 'default')

// Branch gateway BGP settings — conditionally include APIPA custom addresses
// NOTE: APIPA works fine on traditional VPN gateways (branch side)
var branchBgpSettings = union({
  asn: 65010
}, useApipaBgp ? {
  bgpPeeringAddresses: [
    {
      ipconfigurationId: branchGwIpConfigId
      customBgpIpAddresses: [
        branchApipaBgpIp
      ]
    }
  ]
} : {})

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
  name: branchGwName
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    enableBgp: true
    bgpSettings: branchBgpSettings
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
// ║                                                                            ║
// ║  IMPORTANT: vWAN VPN gateways silently ignore customBgpIpAddresses during  ║
// ║  initial ARM/Bicep creation. APIPA addresses MUST be set via REST API PUT  ║
// ║  after the gateway is provisioned and Succeeded. The deploy script handles ║
// ║  this as a post-deployment step (Phase 2).                                 ║
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
    enableBgpRouteTranslationForNat: true
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
    enableBgpRouteTranslationForNat: true
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  VPN NAT Rules — Hub1                                                      ║
// ║                                                                            ║
// ║  IngressSnat: Branch → Hub traffic. Source IP translated from private to    ║
// ║               public range so spokes see branch as the external range.     ║
// ║                                                                            ║
// ║  Static: 1:1 mapping, same-size prefixes, both sides can initiate.         ║
// ║  Dynamic: Many-to-few with PAT, only NAT'd side can initiate.             ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource hub1IngressNat 'Microsoft.Network/vpnGateways/natRules@2023-11-01' = {
  parent: hub1VpnGw
  name: 'IngressSnat-Branch1'
  properties: {
    type: natType
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

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  VPN NAT Rules — Hub1 EgressSnat (Optional)                               ║
// ║                                                                            ║
// ║  EgressSnat: Hub → Branch traffic. Source IP of spoke VMs translated to    ║
// ║              the external range so the branch sees a different address.    ║
// ║                                                                            ║
// ║  Use case: Present spoke 172.16.2.0/26 as 203.0.113.0/26 to a remote     ║
// ║  partner (e.g., IPSEC worksheet requiring specific address ranges).       ║
// ║                                                                            ║
// ║  NOTE: Do NOT use the same external range for both IngressSnat and        ║
// ║  EgressSnat on the same connection — Azure silently drops the egress      ║
// ║  attachment. Use different external ranges.                                ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource hub1EgressNat 'Microsoft.Network/vpnGateways/natRules@2023-11-01' = if (enableHub1EgressSnat) {
  parent: hub1VpnGw
  name: 'EgressSnat-Spoke2'
  properties: {
    type: 'Static'
    mode: 'EgressSnat'
    internalMappings: [
      {
        addressSpace: hub1EgressInternalRange
      }
    ]
    externalMappings: [
      {
        addressSpace: hub1EgressExternalRange
      }
    ]
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  VPN NAT Rules — Hub2                                                      ║
// ║                                                                            ║
// ║  Same pattern as Hub1 but maps to a different public range                 ║
// ║  demonstrating per-hub NAT independence.                                   ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

resource hub2IngressNat 'Microsoft.Network/vpnGateways/natRules@2023-11-01' = {
  parent: hub2VpnGw
  name: 'IngressSnat-Branch1'
  properties: {
    type: natType
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
            bgpPeeringAddress: useApipaBgp ? branchApipaBgpIp : branchVpnGateway.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
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
// ║  Hub → Branch VPN Connections (with NAT rules)                             ║
// ║                                                                            ║
// ║  Hub connections are created WITHOUT vpnGatewayCustomBgpAddresses.         ║
// ║  When APIPA BGP is enabled, the deploy script updates these connections    ║
// ║  via REST API after setting APIPA on the hub gateways (Phase 3).           ║
// ║                                                                            ║
// ║  This two-phase approach is needed because vWAN VPN gateways silently      ║
// ║  ignore customBgpIpAddresses during ARM creation — the APIPA addresses     ║
// ║  must be set on the gateway first, then connections can reference them.     ║
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
          egressNatRules: enableHub1EgressSnat ? [
            {
              id: hub1EgressNat.id
            }
          ] : []
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
        }
      }
    ]
  }
  dependsOn: [
    hub2IngressNat
  ]
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Local Network Gateways + Branch-side VPN Connections                      ║
// ║                                                                            ║
// ║  When APIPA BGP is enabled, the LNGs use APIPA addresses for BGP          ║
// ║  peering instead of the hub's default private IPs. The branch connections  ║
// ║  specify which APIPA address the branch gateway uses for each tunnel.      ║
// ║                                                                            ║
// ║  NOTE: APIPA works perfectly on traditional (non-vWAN) VPN gateways.      ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

// Local Gateways for Hub1
resource lngHub1Gw1 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-${hub1Name}-gw1'
  location: location
  properties: {
    gatewayIpAddress: hub1VpnGw.properties.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: useApipaBgp ? hub1ApipaInstance0 : hub1VpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
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
      bgpPeeringAddress: useApipaBgp ? hub1ApipaInstance1 : hub1VpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
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
      bgpPeeringAddress: useApipaBgp ? hub2ApipaInstance0 : hub2VpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
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
      bgpPeeringAddress: useApipaBgp ? hub2ApipaInstance1 : hub2VpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
    }
  }
}

// VPN Connections from Branch to Hubs (with optional APIPA BGP)
// NOTE: Branch-side connections use gatewayCustomBgpIpAddresses which works
// fine on traditional VPN gateways (unlike vWAN gateways).
resource branchToHub1Gw1Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-to-${hub1Name}-gw1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branchVpnGateway.id
      properties: {}
    }
    localNetworkGateway2: {
      id: lngHub1Gw1.id
      properties: {}
    }
    sharedKey: 'abc123'
    enableBgp: true
    gatewayCustomBgpIpAddresses: useApipaBgp ? [
      {
        ipConfigurationId: branchGwIpConfigId
        customBgpIpAddress: branchApipaBgpIp
      }
    ] : []
  }
}

resource branchToHub1Gw2Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-to-${hub1Name}-gw2'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branchVpnGateway.id
      properties: {}
    }
    localNetworkGateway2: {
      id: lngHub1Gw2.id
      properties: {}
    }
    sharedKey: 'abc123'
    enableBgp: true
    gatewayCustomBgpIpAddresses: useApipaBgp ? [
      {
        ipConfigurationId: branchGwIpConfigId
        customBgpIpAddress: branchApipaBgpIp
      }
    ] : []
  }
}

resource branchToHub2Gw1Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-to-${hub2Name}-gw1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branchVpnGateway.id
      properties: {}
    }
    localNetworkGateway2: {
      id: lngHub2Gw1.id
      properties: {}
    }
    sharedKey: 'abc123'
    enableBgp: true
    gatewayCustomBgpIpAddresses: useApipaBgp ? [
      {
        ipConfigurationId: branchGwIpConfigId
        customBgpIpAddress: branchApipaBgpIp
      }
    ] : []
  }
}

resource branchToHub2Gw2Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-to-${hub2Name}-gw2'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branchVpnGateway.id
      properties: {}
    }
    localNetworkGateway2: {
      id: lngHub2Gw2.id
      properties: {}
    }
    sharedKey: 'abc123'
    enableBgp: true
    gatewayCustomBgpIpAddresses: useApipaBgp ? [
      {
        ipConfigurationId: branchGwIpConfigId
        customBgpIpAddress: branchApipaBgpIp
      }
    ] : []
  }
}

// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Outputs                                                                   ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

output branchVpnGatewayId string = branchVpnGateway.id
output hub1VpnGwId string = hub1VpnGw.id
output hub2VpnGwId string = hub2VpnGw.id
output hub1VpnGwName string = hub1VpnGw.name
output hub2VpnGwName string = hub2VpnGw.name
output hub1ConnName string = hub1BranchConn.name
output hub2ConnName string = hub2BranchConn.name
output vpnSiteId string = vpnSite.id
output hub1IngressNatId string = hub1IngressNat.id
output hub2IngressNatId string = hub2IngressNat.id
output hub1EgressNatId string = enableHub1EgressSnat ? hub1EgressNat.id : 'N/A (EgressSnat not enabled)'
output natRuleType string = natType
output apipaBgpEnabled bool = useApipaBgp
output branchApipaBgpAddress string = useApipaBgp ? branchApipaBgpIp : 'N/A (using default BGP IPs)'
