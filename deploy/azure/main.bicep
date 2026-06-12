// Azure VM that hosts the Oracle -> Azure PostgreSQL migration web app
// plus every CLI tool the 7-step flow needs (ora2pg, Oracle Instant Client,
// Node, code-server, Azure CLI, psql).
//
// Access model: Microsoft Entra ID SSH login over Azure Bastion (no SSH keys,
// no public port 22). Connect with:
//   az network bastion ssh -n oracle-bridge-bastion -g <rg> \
//     --target-resource-id <vm-id> --auth-type AAD --username <you@domain>
//
//   az group create -n oracle-bridge-rg -l westeurope
//   az deployment group create -g oracle-bridge-rg -f main.bicep \
//     -p adminUsername=azureuser \
//        adminLoginPrincipalId=$(az ad signed-in-user show --query id -o tsv) \
//        foundryEndpoint=https://<your>.openai.azure.com \
//        foundryApiKey=<key> foundryDeployment=gpt-5.2 \
//        appRepoUrl=https://github.com/<you>/<repo>.git

@description('Admin username for the VM.')
param adminUsername string

@description('Optional SSH public key. Leave empty to rely solely on Microsoft Entra ID login over Bastion.')
@secure()
param sshPublicKey string = ''

@description('Enable Microsoft Entra ID SSH login (AADSSHLoginForLinux extension). Recommended.')
param enableEntraLogin bool = true

@description('Object ID of the user or group to grant Virtual Machine Administrator Login. Leave empty to assign the role yourself later.')
param adminLoginPrincipalId string = ''

@description('Principal type for the admin login role assignment.')
@allowed([ 'User', 'Group', 'ServicePrincipal' ])
param adminLoginPrincipalType string = 'User'

@description('Azure region. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('VM size. D4s_v5 = 4 vCPU / 16 GB, enough for ora2pg + code-server.')
param vmSize string = 'Standard_D4s_v5'

@description('DNS label prefix for the public IP. Must be globally unique in the region.')
param dnsLabelPrefix string = 'oracle-bridge-${uniqueString(resourceGroup().id)}'

@description('Azure AI Foundry endpoint (https://<resource>.openai.azure.com).')
param foundryEndpoint string

@description('Azure AI Foundry API key.')
@secure()
param foundryApiKey string

@description('Foundry deployment name (e.g. gpt-5.2).')
param foundryDeployment string = 'gpt-5.2'

@description('Git URL of the web app repo to clone and run on the VM.')
param appRepoUrl string

@description('CIDR allowed to reach the web app and code-server. Lock down to your IP.')
param allowedSourceCidr string = '*'

var vnetName     = 'oracle-bridge-vnet'
var subnetName   = 'default'
var nsgName      = 'oracle-bridge-nsg'
var pipName      = 'oracle-bridge-pip'
var nicName      = 'oracle-bridge-nic'
var vmName       = 'oracle-bridge-vm'
var bastionName  = 'oracle-bridge-bastion'

// Built-in role: Virtual Machine Administrator Login
var vmAdminLoginRoleId = '1c0163c0-47e6-4577-8991-ea5c82e286e4'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'HTTPS'
        properties: {
          priority: 1010, protocol: 'Tcp', access: 'Allow', direction: 'Inbound'
          sourceAddressPrefix: allowedSourceCidr, sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '443'
        }
      }
      {
        name: 'HTTP'
        properties: {
          priority: 1020, protocol: 'Tcp', access: 'Allow', direction: 'Inbound'
          sourceAddressPrefix: allowedSourceCidr, sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '80'
        }
      }
      {
        name: 'CodeServer'
        properties: {
          priority: 1030, protocol: 'Tcp', access: 'Allow', direction: 'Inbound'
          sourceAddressPrefix: allowedSourceCidr, sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '8443'
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

var cloudInit = base64(replace(replace(replace(replace(loadTextContent('cloud-init.yaml'),
  '__FOUNDRY_ENDPOINT__',   foundryEndpoint),
  '__FOUNDRY_API_KEY__',    foundryApiKey),
  '__FOUNDRY_DEPLOYMENT__', foundryDeployment),
  '__APP_REPO_URL__',       appRepoUrl))

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: empty(sshPublicKey) ? null : {
          publicKeys: [ {
            path: '/home/${adminUsername}/.ssh/authorized_keys'
            keyData: sshPublicKey
          } ]
        }
      }
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
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
  }
}

// Microsoft Entra ID SSH login — no key files, identity-based access.
resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = if (enableEntraLogin) {
  parent: vm
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

// Grant the chosen principal the right to sign in to the VM as admin.
resource vmAdminLoginAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminLoginPrincipalId)) {
  name: guid(vm.id, adminLoginPrincipalId, vmAdminLoginRoleId)
  scope: vm
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmAdminLoginRoleId)
    principalId: adminLoginPrincipalId
    principalType: adminLoginPrincipalType
  }
}

// Azure Bastion — private SSH access, no public port 22. Standard SKU with
// tunneling enabled so `az network bastion ssh --auth-type AAD` works.
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

output publicFqdn   string = pip.properties.dnsSettings.fqdn
output webAppUrl    string = 'https://${pip.properties.dnsSettings.fqdn}'
output codeServer   string = 'https://${pip.properties.dnsSettings.fqdn}:8443'
output vmResourceId string = vm.id
output bastionSshCommand string = 'az network bastion ssh -n ${bastionName} -g ${resourceGroup().name} --target-resource-id ${vm.id} --auth-type AAD --username <you@domain>'
