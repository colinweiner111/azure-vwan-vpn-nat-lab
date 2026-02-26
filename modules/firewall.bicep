param location string
param firewallSku string
param hub1Name string
param hub2Name string

// Hub1 Firewall Policy
resource hub1FwPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: '${hub1Name}-fwpolicy'
  location: location
  properties: {
    sku: {
      tier: firewallSku
    }
    dnsSettings: {
      enableProxy: true
    }
  }
}

resource hub1FwPolicyRuleGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: hub1FwPolicy
  name: 'NetworkRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'GenericCollection'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AnytoAny'
            ipProtocols: [
              'Any'
            ]
            sourceAddresses: [
              '*'
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '*'
            ]
          }
        ]
      }
    ]
  }
}

// Hub2 Firewall Policy
resource hub2FwPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: '${hub2Name}-fwpolicy'
  location: location
  properties: {
    sku: {
      tier: firewallSku
    }
    dnsSettings: {
      enableProxy: true
    }
  }
}

resource hub2FwPolicyRuleGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: hub2FwPolicy
  name: 'NetworkRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'GenericCollection'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AnytoAny'
            ipProtocols: [
              'Any'
            ]
            sourceAddresses: [
              '*'
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '*'
            ]
          }
        ]
      }
    ]
  }
}

// Hub1 Azure Firewall
resource hub1Firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: '${hub1Name}-azfw'
  location: location
  properties: {
    sku: {
      name: 'AZFW_Hub'
      tier: firewallSku
    }
    virtualHub: {
      id: resourceId('Microsoft.Network/virtualHubs', hub1Name)
    }
    hubIPAddresses: {
      publicIPs: {
        count: 1
      }
    }
    firewallPolicy: {
      id: hub1FwPolicy.id
    }
  }
}

// Hub2 Azure Firewall
resource hub2Firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: '${hub2Name}-azfw'
  location: location
  properties: {
    sku: {
      name: 'AZFW_Hub'
      tier: firewallSku
    }
    virtualHub: {
      id: resourceId('Microsoft.Network/virtualHubs', hub2Name)
    }
    hubIPAddresses: {
      publicIPs: {
        count: 1
      }
    }
    firewallPolicy: {
      id: hub2FwPolicy.id
    }
  }
}

// Log Analytics Workspaces
resource hub1LogWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${hub1Name}-${location}-Logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource hub2LogWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${hub2Name}-${location}-Logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Diagnostic Settings for Hub1 Firewall
resource hub1FwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: hub1Firewall
  name: 'toLogAnalytics'
  properties: {
    workspaceId: hub1LogWorkspace.id
    logs: [
      {
        category: 'AzureFirewallApplicationRule'
        enabled: true
      }
      {
        category: 'AzureFirewallNetworkRule'
        enabled: true
      }
      {
        category: 'AzureFirewallDnsProxy'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Diagnostic Settings for Hub2 Firewall
resource hub2FwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: hub2Firewall
  name: 'toLogAnalytics'
  properties: {
    workspaceId: hub2LogWorkspace.id
    logs: [
      {
        category: 'AzureFirewallApplicationRule'
        enabled: true
      }
      {
        category: 'AzureFirewallNetworkRule'
        enabled: true
      }
      {
        category: 'AzureFirewallDnsProxy'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Hub1 Routing Intent - InternetAndPrivate
resource hub1RoutingIntent 'Microsoft.Network/virtualHubs/routingIntent@2023-11-01' = {
  name: '${hub1Name}/${hub1Name}_RoutingIntent'
  properties: {
    routingPolicies: [
      {
        name: 'InternetTraffic'
        destinations: [
          'Internet'
        ]
        nextHop: hub1Firewall.id
      }
      {
        name: 'PrivateTraffic'
        destinations: [
          'PrivateTraffic'
        ]
        nextHop: hub1Firewall.id
      }
    ]
  }
  dependsOn: [
    hub1Firewall
  ]
}

// Hub2 Routing Intent - InternetAndPrivate
resource hub2RoutingIntent 'Microsoft.Network/virtualHubs/routingIntent@2023-11-01' = {
  name: '${hub2Name}/${hub2Name}_RoutingIntent'
  properties: {
    routingPolicies: [
      {
        name: 'InternetTraffic'
        destinations: [
          'Internet'
        ]
        nextHop: hub2Firewall.id
      }
      {
        name: 'PrivateTraffic'
        destinations: [
          'PrivateTraffic'
        ]
        nextHop: hub2Firewall.id
      }
    ]
  }
  dependsOn: [
    hub2Firewall
  ]
}

output hub1FirewallId string = hub1Firewall.id
output hub2FirewallId string = hub2Firewall.id
output hub1FwPolicyId string = hub1FwPolicy.id
output hub2FwPolicyId string = hub2FwPolicy.id
