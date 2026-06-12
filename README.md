# azure-oracle-pg-migrator

A **VNet-integrated Windows workstation** for the official Oracle → Azure Database for
PostgreSQL schema conversion feature. One Windows Server 2022 VM runs **desktop Visual
Studio Code + the Microsoft PostgreSQL extension**, which performs the AI conversion via
**Microsoft Foundry** and validates it against a **scratch Azure Database for PostgreSQL**
server. The VM lives inside the virtual network so it can reach a privately networked
Oracle source that a laptop can't. No custom conversion logic runs here — the extension
does the work.

## Deploy to Azure

Click the button, sign in to the Azure portal, fill in the form (admin username, password,
VM size, and optional Foundry endpoint), and select **Review + create**. No CLI required.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2Fazuredeploy.json)

After the deployment finishes, see [Connect to the workstation](deploy/azure/DEPLOYMENT.md#connect)
to open the Azure Bastion RDP tunnel and start the Migration Wizard.

## What's in this repo

| Path | Purpose |
|---|---|
| [deploy/azure/azuredeploy.json](deploy/azure/azuredeploy.json) | Compiled ARM template behind the **Deploy to Azure** button |
| [deploy/azure/createUiDefinition.json](deploy/azure/createUiDefinition.json) | Portal form definition for the one-click deployment |
| [deploy/azure/main.bicep](deploy/azure/main.bicep) | Bicep source — provisions the VM, VNet, NSG, public IP, and Azure Bastion |
| [deploy/azure/setup.ps1](deploy/azure/setup.ps1) | PowerShell run by an Azure Run Command — installs VS Code + PostgreSQL extension + Oracle Instant Client + Azure CLI |
| [deploy/azure/DEPLOYMENT.md](deploy/azure/DEPLOYMENT.md) | Detailed deployment guide and the in-editor workflow |
| [deploy/azure/schema-conversions-vm-workstation.md](deploy/azure/schema-conversions-vm-workstation.md) | Microsoft Learn-style article describing the workstation approach |

## Deploy from the command line (optional)

If you prefer the CLI over the portal button:

```bash
az group create -n oracle-bridge-rg -l westeurope

az deployment group create -g oracle-bridge-rg -f deploy/azure/main.bicep \
  -p adminUsername=azureuser \
     adminPassword='<strong-password>' \
     foundryEndpoint="https://YOUR-FOUNDRY.openai.azure.com" \
     foundryDeployment="gpt-5.2"
```

The deployment outputs `publicFqdn`, `vmResourceId`, and `bastionRdpTunnelCommand`.
Access is **RDP only, via an Azure Bastion tunnel** — no SSH, no public RDP port, no
public web ports. Open the tunnel, RDP to `localhost:13389` with the password you set,
then use VS Code. Reset the password later via `az vm run-command`.

See [deploy/azure/DEPLOYMENT.md](deploy/azure/DEPLOYMENT.md) for prerequisites, connection
steps, the in-editor workflow, security notes, and tear-down.

## The workflow

| Step | In VS Code | Backed by |
|---|---|---|
| 1 Connect to Oracle | Add the Oracle connection in the PostgreSQL extension | Oracle Instant Client (thick mode) over the VNet |
| 2 Connect target | Add the scratch Azure Database for PostgreSQL server | Azure CLI / Entra ID |
| 3 Convert | Run the Migration Wizard | Microsoft Foundry deployment |
| 4 Review | Inspect and refine the generated schema | GitHub Copilot Chat |
| 5 Validate | Apply to the scratch database and verify | PostgreSQL extension |

## Security

- RDP only, via an Azure Bastion tunnel — no SSH, no public RDP port; RDP (3389) is reachable only from the virtual network.
- No public web ports.
- The login password is a `@secure()` deploy-time parameter (not stored in the template) and can be rotated with `az vm run-command`.
- The VM uses a system-assigned managed identity; grant it only the least-privileged roles it needs.
- Independently validate all converted objects before deploying to production.
