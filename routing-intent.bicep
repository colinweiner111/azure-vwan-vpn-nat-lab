@description('Virtual Hub name')
param hubname string

@description('Next hop resource ID (Azure Firewall)')
param nexthop string

@allowed([
  'PrivateOnly'
  'InternetAndPrivate'
])
@description('Routing Intent scenario option')
param scenarioOption string = 'PrivateOnly'

resource vhub 'Microsoft.Network/virtualHubs@2023-04-01' existing = {
  name: hubname
}

resource routingIntent 'Microsoft.Network/virtualHubs/routingIntent@2023-04-01' = {
  parent: vhub
  name: '${hubname}_RoutingIntent'
  properties: {
    routingPolicies: scenarioOption == 'PrivateOnly' ? [
      {
        name: 'PrivateTraffic'
        destinations: [
          'PrivateTraffic'
        ]
        nextHop: nexthop
      }
    ] : [
      {
        name: 'InternetTraffic'
        destinations: [
          'Internet'
        ]
        nextHop: nexthop
      }
      {
        name: 'PrivateTraffic'
        destinations: [
          'PrivateTraffic'
        ]
        nextHop: nexthop
      }
    ]
  }
}
