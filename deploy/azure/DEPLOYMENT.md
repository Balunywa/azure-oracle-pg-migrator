# Azure VM deployment — schema conversion workstation

This package provisions a single **Windows Server 2022** Azure VM as a **VNet-integrated
workstation** for the official Oracle → Azure Database for PostgreSQL schema conversion
feature. The VM runs **desktop Visual Studio Code + the Microsoft PostgreSQL extension**,
which performs the AI conversion through **Microsoft Foundry** and validates it against a
**scratch Azure Database for PostgreSQL** server — exactly the local workflow, but inside
the virtual network so it can reach a privately networked Oracle source.

No custom conversion logic runs on this VM. The PostgreSQL extension's Migration Wizard
does the work; the VM only provides a place to run it that has line of sight to Oracle.

## What gets installed on the VM

| Layer | Tool | Purpose |
|---|---|---|
| Editor | Visual Studio Code (desktop) | Hosts the official conversion experience |
| Conversion | PostgreSQL extension (`ms-ossdata.vscode-pgsql`) | Migration Wizard + Microsoft Foundry conversion |
| Assist | GitHub Copilot + Copilot Chat | In-editor guidance during review |
| Oracle | Oracle Instant Client 21 (thick client mode) | Native Oracle Net encryption to the source |
| Cloud | Azure CLI | `az login` for Microsoft Entra ID / Foundry / target DB |
| OS | Windows Server 2022 (Desktop Experience) | Built-in RDP, reached privately over Bastion |

The VM is provisioned by an Azure **Run Command** that executes `setup.ps1`. Progress is
logged to `C:\oracle-workstation-setup.log` on the VM (ends with `PROVISION_COMPLETE`).
The PostgreSQL extension and Copilot finish installing at your first interactive logon.

## Prerequisites

- Azure subscription + `az` CLI logged in
- A strong password for the VM admin account (used for the RDP login; must meet Windows complexity rules)
- A Microsoft Foundry resource + model deployment for the conversion (the extension prompts for the endpoint/deployment)
- A scratch Azure Database for PostgreSQL flexible server the extension can validate against
- Network path from the VM's subnet to your Oracle DB (VNet peering, private endpoint, or VPN). The Bicep creates `10.42.0.0/16` — peer it with whatever holds Oracle.

## Access model

The VM is **RDP only, via an Azure Bastion tunnel** — no SSH, no public RDP port, and no
public web ports. RDP (3389) is allowed solely from within the virtual network, so the
only way in is the Bastion tunnel. The login password is set at deploy time
(`adminPassword`); reset it later without a console using `az vm run-command`.

## Deploy

The simplest path is the one-click **Deploy to Azure** button, which opens the Azure
portal with a form for the admin username, password, VM size, and optional Foundry
endpoint. No local tooling is required.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2FcreateUiDefinition.json)

To deploy from the command line instead:

```bash
az group create -n oracle-bridge-rg -l westeurope

az deployment group create -g oracle-bridge-rg -f deploy/azure/main.bicep \
  -p adminUsername=azureuser \
     adminPassword='<strong-password>' \
     foundryEndpoint="https://YOUR-FOUNDRY.openai.azure.com" \
     foundryDeployment="gpt-5.2"
```

Outputs include `publicFqdn`, `vmResourceId`, and `bastionRdpTunnelCommand`.

## Connect

```bash
# Open an RDP tunnel through Bastion, then RDP to localhost:13389:
az network bastion tunnel -n oracle-bridge-bastion -g oracle-bridge-rg \
  --target-resource-id <vmResourceId> --resource-port 3389 --port 13389
```

RDP to `localhost:13389`, sign in as the workstation user with the password you set,
open Visual Studio Code, run `az login`, then open the **PostgreSQL** extension and start
the **Migration Wizard**.

To reset the login password later without a console:

```bash
az vm run-command invoke -g oracle-bridge-rg -n oracle-bridge-vm \
  --command-id RunPowerShellScript \
  --scripts "net user azureuser '<new-password>'"
```

## What you do in the workstation

| Step | In VS Code | Backed by |
|---|---|---|
| 1 Connect to Oracle | Add the Oracle connection in the PostgreSQL extension | Oracle Instant Client (thick mode) over the VNet |
| 2 Connect target | Add the scratch Azure Database for PostgreSQL server | Azure CLI / Entra ID |
| 3 Convert | Run the Migration Wizard | Microsoft Foundry deployment |
| 4 Review | Inspect and refine the generated schema | Copilot Chat |
| 5 Validate | Apply to the scratch database and verify | PostgreSQL extension |

## Security notes

- No SSH and no public RDP port. The only way in is the Bastion RDP tunnel; RDP (3389) is reachable only from the virtual network.
- No public web ports are opened.
- The login password is supplied at deploy time as a `@secure()` parameter (not stored in the template) and can be rotated later with `az vm run-command`.
- The VM has a SystemAssigned managed identity — grant it the roles you need for passwordless `az` flows against the scratch database.
- The `foundryEndpoint`/`foundryDeployment` values are written to machine environment variables as convenience only; the extension still prompts for and manages credentials.

## Tear down

```bash
az group delete -n oracle-bridge-rg --yes
```
