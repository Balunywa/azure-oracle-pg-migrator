# azure-oracle-pg-migrator

A **complete, self-contained Oracle to Azure Database for PostgreSQL schema-conversion lab**,
deployed by a single **Deploy to Azure** button. One click provisions everything inside a
single virtual network:

- a **Windows workstation** running desktop **Visual Studio Code + the Microsoft PostgreSQL
  extension** (the tool that performs the AI conversion),
- an **Oracle source database** (Oracle Database Free 23ai in a container) pre-seeded with a
  sample **HR** schema,
- an **Azure Database for PostgreSQL flexible server** as the conversion target, and
- an **Azure OpenAI (Microsoft Foundry)** model deployment that powers the AI conversion.

Everything is network-isolated and reached privately over **Azure Bastion**. No custom
conversion logic runs here — the PostgreSQL extension does the work; this repo just stands
up the whole environment for you.

## Deploy to Azure

Click the button, sign in to the Azure portal, fill in the form (admin username and
password, VM sizes, PostgreSQL tier, and model deployment name), and select
**Review + create**. Everything — workstation, Oracle source, PostgreSQL target, and the
Azure OpenAI deployment — is created for you. No CLI required.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2Fazuredeploy.json)

After the deployment finishes, see [Connect to the workstation](deploy/azure/DEPLOYMENT.md#connect)
to open the Azure Bastion RDP tunnel and start the Migration Wizard.

## What's in this repo

| Path | Purpose |
|---|---|
| [deploy/azure/azuredeploy.json](deploy/azure/azuredeploy.json) | Compiled ARM template behind the **Deploy to Azure** button |
| [deploy/azure/createUiDefinition.json](deploy/azure/createUiDefinition.json) | Portal form definition for the one-click deployment |
| [deploy/azure/main.bicep](deploy/azure/main.bicep) | Bicep source — provisions the whole lab: VNet/NSG/Bastion, the Windows workstation, the Oracle source VM, the PostgreSQL flexible server, and the Azure OpenAI deployment |
| [deploy/azure/setup.ps1](deploy/azure/setup.ps1) | PowerShell run by an Azure Run Command — installs VS Code + PostgreSQL extension + Oracle Instant Client + Azure CLI on the workstation |
| [deploy/azure/cloud-init.yaml](deploy/azure/cloud-init.yaml) | Cloud-init for the **Oracle source VM** — installs Docker, runs Oracle Database Free 23ai, and seeds the sample HR schema on first boot |
| [deploy/azure/DEPLOYMENT.md](deploy/azure/DEPLOYMENT.md) | Detailed deployment guide and the in-editor workflow |
| [deploy/azure/schema-conversions-vm-workstation.md](deploy/azure/schema-conversions-vm-workstation.md) | Microsoft Learn-style article describing the workstation approach |

## Deploy from the command line (optional)

If you prefer the CLI over the portal button:

```bash
az group create -n oracle-bridge-rg -l westeurope

az deployment group create -g oracle-bridge-rg -f deploy/azure/main.bicep \
  -p adminUsername=azureuser \
     adminPassword='<strong-password>'
```

The admin username and password are reused for the workstation RDP login and for the
Oracle and PostgreSQL admin accounts. The template also creates an Azure OpenAI model
deployment (default `gpt-5-mini`) and grants the workstation's managed identity the
**Cognitive Services OpenAI User** role — so the deploying identity needs permission to
create role assignments (**Owner** or **User Access Administrator** on the resource group).

> If the deployment fails preflight with a `QuotaExceeded` error for a VM family, your
> subscription has no quota for that size in the region. Run `az vm list-usage -l <region>`
> and pass a size you do have, for example `-p vmSize=Standard_D4s_v3` (workstation) or
> `-p oracleVmSize=Standard_D2s_v3` (Oracle source). If the OpenAI deployment fails with
> a model-deprecation error, pass a currently available model, for example
> `-p openAiModelName=gpt-5-mini openAiModelVersion=2025-08-07`.

The deployment outputs `publicFqdn`, `vmResourceId`, `bastionRdpTunnelCommand`,
`oraclePrivateIp`, `oracleServiceName`, `postgresFqdn`, `postgresAdmin`, `foundryEndpoint`,
and `foundryDeployment`. Access is **RDP only, via an Azure Bastion tunnel** — no SSH, no
public RDP port, no public web ports. Open the tunnel, RDP to `localhost:13389` with the
password you set, then use VS Code. Reset the password later via `az vm run-command`.

See [deploy/azure/DEPLOYMENT.md](deploy/azure/DEPLOYMENT.md) for prerequisites, connection
steps, the in-editor workflow, security notes, and tear-down.

## The workflow

| Step | In VS Code | Backed by |
|---|---|---|
| 1 Connect to Oracle | Add the Oracle connection in the PostgreSQL extension | The in-lab Oracle source VM (service `FREEPDB1`, port 1521) over the VNet |
| 2 Connect target | Add the PostgreSQL flexible server | The in-lab Azure Database for PostgreSQL server |
| 3 Convert | Run the Migration Wizard | The in-lab Azure OpenAI (Microsoft Foundry) deployment |
| 4 Review | Inspect and refine the generated schema | GitHub Copilot Chat |
| 5 Validate | Apply to the PostgreSQL server and verify | PostgreSQL extension |

## Security

- RDP only, via an Azure Bastion tunnel — no SSH, no public RDP port; RDP (3389) is reachable only from the virtual network.
- The Oracle source (1521) and the PostgreSQL flexible server are reachable **only from within the virtual network** — no public database endpoints. PostgreSQL uses private access with a private DNS zone.
- No public web ports.
- The login password is a `@secure()` deploy-time parameter (not stored in the template) and can be rotated with `az vm run-command`. It is reused for the Oracle and PostgreSQL admin accounts for lab convenience — change them for anything beyond a lab.
- The workstation uses a system-assigned managed identity, granted only the **Cognitive Services OpenAI User** role on the lab's Azure OpenAI account.
- Independently validate all converted objects before deploying to production.
