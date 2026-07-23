// Azure VM that hosts a VNet-integrated Windows workstation for the OFFICIAL
// Oracle -> Azure Database for PostgreSQL schema conversion feature: desktop
// VS Code + the Microsoft PostgreSQL extension (Migration Wizard / Microsoft
// Foundry) + Oracle Instant Client + Azure CLI. The VM runs inside the virtual
// network so it can reach a privately networked Oracle source; no conversion
// logic runs here.
//
// Access model: RDP only, via an Azure Bastion tunnel. No public RDP port, no
// public web ports. The login password is set at deploy time (adminPassword);
// reset it later without a console using `az vm run-command`. Connect:
//   az network bastion tunnel -n oracle-bridge-bastion -g <rg> \
//     --target-resource-id <vm-id> --resource-port 3389 --port 13389
//   # then RDP to localhost:13389
//
//   az group create -n oracle-bridge-rg -l westeurope
//   az deployment group create -g oracle-bridge-rg -f main.bicep \
//     -p adminUsername=azureuser adminPassword='<strong-password>' \
//        foundryEndpoint=https://<your>.openai.azure.com \
//        foundryDeployment=gpt-5.2

@description('Admin username for the workstation VM (RDP login) and the Oracle and PostgreSQL admin accounts.')
param adminUsername string

@description('Password for the RDP login and for the Oracle and PostgreSQL admin accounts. Must satisfy Windows, Oracle, and PostgreSQL complexity rules.')
@secure()
param adminPassword string

@description('Azure region. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('Workstation VM size. D4s_v3 = 4 vCPU / 16 GB and is broadly available. If you prefer a newer family and have quota, use a Dsv5/Dasv5 size (for example Standard_D4s_v5).')
param vmSize string = 'Standard_D4s_v3'

@description('Oracle source VM size (Linux; runs Oracle Database Free 23ai in a container).')
param oracleVmSize string = 'Standard_D2s_v3'

@description('PostgreSQL flexible server compute tier. The compute SKU size is derived from this tier.')
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param postgresSkuTier string = 'Burstable'

@description('PostgreSQL major version.')
param postgresVersion string = '16'

@description('Name of the Azure OpenAI (Microsoft Foundry) model deployment used for the conversion.')
param openAiDeploymentName string = 'gpt-5-mini'

@description('Azure OpenAI model name.')
param openAiModelName string = 'gpt-5-mini'

@description('Azure OpenAI model version.')
param openAiModelVersion string = '2025-08-07'

@description('Azure OpenAI deployment SKU. GlobalStandard is broadly available for gpt-5-mini.')
param openAiSkuName string = 'GlobalStandard'

@description('Azure OpenAI deployment capacity, in thousands of tokens per minute (TPM).')
param openAiCapacity int = 10

@description('DNS label prefix for the workstation public IP. Must be globally unique in the region.')
param dnsLabelPrefix string = 'oracle-bridge-${uniqueString(resourceGroup().id)}'

var suffix       = uniqueString(resourceGroup().id)
var vnetName     = 'oracle-bridge-vnet'
var subnetName   = 'default'
var oracleSubnet = 'oracle'
var pgSubnet     = 'postgres'
var nsgName      = 'oracle-bridge-nsg'
var pipName      = 'oracle-bridge-pip'
var nicName      = 'oracle-bridge-nic'
var vmName       = 'oracle-bridge-vm'
var bastionName  = 'oracle-bridge-bastion'
var oracleVmName = 'oracle-source-vm'
var oracleNicName = 'oracle-source-nic'
var pgName       = 'orabridge-pg-${suffix}'
var openaiName   = 'orabridge-oai-${suffix}'
var pgDnsZoneName = '${pgName}.private.postgres.database.azure.com'

// PostgreSQL compute SKU size, derived from the selected tier so the two always match.
var pgSkuNameMap = {
  Burstable: 'Standard_B2s'
  GeneralPurpose: 'Standard_D2ds_v5'
  MemoryOptimized: 'Standard_E2ds_v5'
}
var pgSkuName = pgSkuNameMap[postgresSkuTier]

// Windows computer names must be <= 15 characters.
var computerName = 'ora-bridge-vm'

// Cloud-init for the Oracle source VM, with deploy-time values substituted in.
var oracleCloudInit = replace(replace(loadTextContent('cloud-init.yaml'),
  '__ADMIN_USERNAME__', adminUsername),
  '__ORACLE_PWD__',     adminPassword)

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    // No public inbound web ports. The desktop is reached only over Azure
    // Bastion: RDP (3389) is allowed solely from within the virtual network.
    securityRules: [
      {
        name: 'AllowRdpFromBastion'
        properties: {
          priority: 1000, protocol: 'Tcp', access: 'Allow', direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '3389'
        }
      }
      {
        name: 'AllowOracleFromVnet'
        properties: {
          priority: 1010, protocol: 'Tcp', access: 'Allow', direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '1521'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.42.0.0/16' ] }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.42.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.42.2.0/26'
        }
      }
      {
        name: oracleSubnet
        properties: {
          addressPrefix: '10.42.3.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
      {
        name: pgSubnet
        properties: {
          addressPrefix: '10.42.4.0/24'
          delegations: [ {
            name: 'pgFlex'
            properties: { serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers' }
          } ]
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: dnsLabelPrefix }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [ {
      name: 'ipconfig1'
      properties: {
        subnet: { id: '${vnet.id}/subnets/${subnetName}' }
        privateIPAllocationMethod: 'Dynamic'
        publicIPAddress: { id: pip.id }
      }
    } ]
  }
}

// PowerShell setup script, with the auto-provisioned Foundry (Azure OpenAI)
// endpoint and deployment name substituted in. Referencing openai.properties
// here makes the workstation install wait until Foundry exists.
var setupScript = replace(replace(loadTextContent('setup.ps1'),
  '__FOUNDRY_ENDPOINT__',   openai.properties.endpoint),
  '__FOUNDRY_DEPLOYMENT__', openAiDeploymentName)

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer:     'WindowsServer'
        sku:       '2022-datacenter-azure-edition'
        version:   'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
  }
}

// Install VS Code + PostgreSQL extension + Oracle Instant Client + Azure CLI.
// Run Command takes the PowerShell inline — no storage account, no public ports.
resource setup 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  name: 'install-workstation'
  location: location
  properties: {
    source: { script: setupScript }
    timeoutInSeconds: 3600
    asyncExecution: false
  }
}

// Azure Bastion — private RDP access via a tunnel, no public port 22/3389.
// Standard SKU with tunneling enabled so `az network bastion tunnel` works.
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${bastionName}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: bastionName
  location: location
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true
    ipConfigurations: [ {
      name: 'IpConf'
      properties: {
        subnet: { id: '${vnet.id}/subnets/AzureBastionSubnet' }
        publicIPAddress: { id: bastionPip.id }
      }
    } ]
  }
}

// ---------------------------------------------------------------------------
// Oracle source: Ubuntu VM running Oracle Database Free 23ai in a container,
// seeded with a sample HR schema. Reachable privately on 1521 from the VNet.
// ---------------------------------------------------------------------------
resource oracleNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: oracleNicName
  location: location
  properties: {
    ipConfigurations: [ {
      name: 'ipconfig1'
      properties: {
        subnet: { id: '${vnet.id}/subnets/${oracleSubnet}' }
        privateIPAllocationMethod: 'Dynamic'
      }
    } ]
  }
}

resource oracleVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: oracleVmName
  location: location
  properties: {
    hardwareProfile: { vmSize: oracleVmSize }
    osProfile: {
      computerName: 'oracle-source'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(oracleCloudInit)
      linuxConfiguration: { disablePasswordAuthentication: false }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer:     'ubuntu-24_04-lts'
        sku:       'server'
        version:   'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: { networkInterfaces: [ { id: oracleNic.id } ] }
  }
}

// ---------------------------------------------------------------------------
// Scratch/target: Azure Database for PostgreSQL flexible server (private access
// integrated into the VNet, reachable on 5432 from the workstation).
// ---------------------------------------------------------------------------
resource pgDns 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: pgDnsZoneName
  location: 'global'
}

resource pgDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: pgDns
  name: 'vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: pgName
  location: location
  sku: { name: pgSkuName, tier: postgresSkuTier }
  properties: {
    version: postgresVersion
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    storage: { storageSizeGB: 32 }
    network: {
      delegatedSubnetResourceId: '${vnet.id}/subnets/${pgSubnet}'
      privateDnsZoneArmResourceId: pgDns.id
    }
    highAvailability: { mode: 'Disabled' }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
  }
  dependsOn: [ pgDnsLink ]
}

// ---------------------------------------------------------------------------
// Microsoft Foundry: Azure OpenAI account + model deployment that powers the
// AI conversion. The workstation's managed identity is granted key-less access.
// ---------------------------------------------------------------------------
resource openai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: openaiName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: openaiName
    publicNetworkAccess: 'Enabled'
  }
}

resource openaiDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openai
  name: openAiDeploymentName
  sku: { name: openAiSkuName, capacity: openAiCapacity }
  properties: {
    model: { format: 'OpenAI', name: openAiModelName, version: openAiModelVersion }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

// Cognitive Services OpenAI User role, so the workstation can call Foundry
// with its managed identity instead of an API key.
var openAiUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
resource openaiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openai.id, vm.id, openAiUserRoleId)
  scope: openai
  properties: {
    roleDefinitionId: openAiUserRoleId
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output publicFqdn   string = pip.properties.dnsSettings.fqdn
output vmResourceId string = vm.id
output bastionRdpTunnelCommand string = 'az network bastion tunnel -n ${bastionName} -g ${resourceGroup().name} --target-resource-id ${vm.id} --resource-port 3389 --port 13389  # then RDP to localhost:13389'
output oraclePrivateIp string = oracleNic.properties.ipConfigurations[0].properties.privateIPAddress
output oracleServiceName string = 'FREEPDB1'
output postgresFqdn string = postgres.properties.fullyQualifiedDomainName
output postgresAdmin string = adminUsername
output foundryEndpoint string = openai.properties.endpoint
output foundryDeployment string = openAiDeploymentName
