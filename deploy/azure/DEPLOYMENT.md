# Azure deployment — Oracle to PostgreSQL schema-conversion lab

This package provisions a **complete, self-contained schema-conversion lab** inside a single
virtual network:

- a **Windows Server 2022** workstation running desktop **Visual Studio Code + the Microsoft
  PostgreSQL extension**,
- an **Oracle source database** (Oracle Database Free 23ai in a container) pre-seeded with a
  sample **HR** schema,
- an **Azure Database for PostgreSQL flexible server** (private access) as the target, and
- an **Azure OpenAI (Microsoft Foundry)** model deployment that powers the AI conversion.

The workstation performs the conversion through Azure OpenAI and validates it against the
PostgreSQL server — exactly the local workflow, but entirely inside the virtual network so
it can reach the privately networked Oracle source.

No custom conversion logic runs on the workstation. The PostgreSQL extension's Migration
Wizard does the work; the lab only stands up an environment that has line of sight to
Oracle, PostgreSQL, and Azure OpenAI.

## What gets deployed

| Component | Resource | Notes |
|---|---|---|
| Workstation | Windows Server 2022 VM (`oracle-bridge-vm`) | VS Code + PostgreSQL extension + Oracle Instant Client + Azure CLI; system-assigned identity |
| Oracle source | Ubuntu VM (`oracle-source-vm`) | Runs Oracle Database Free 23ai in a container, seeded with the HR schema; service `FREEPDB1`, port 1521 |
| PostgreSQL target | Azure Database for PostgreSQL flexible server | Private access into a delegated subnet + private DNS zone; no public endpoint |
| AI conversion | Azure OpenAI account + model deployment | Default model `gpt-5-mini`; workstation identity granted **Cognitive Services OpenAI User** |
| Network | VNet `10.42.0.0/16`, NSG, Azure Bastion (Standard) | Bastion tunneling for private RDP; subnets for default, Bastion, Oracle, and PostgreSQL |

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
- Permission to **create role assignments** in the target resource group (**Owner** or **User Access Administrator**). The template grants the workstation identity the Cognitive Services OpenAI User role; without this permission the deployment fails at the role assignment.
- The `Microsoft.CognitiveServices` and `Microsoft.DBforPostgreSQL` resource providers registered in the subscription (`az provider register --namespace Microsoft.CognitiveServices` / `Microsoft.DBforPostgreSQL`)
- The Azure CLI **`bastion`** extension for the connection step (`az extension add -n bastion`, or allow dynamic install)
- A strong password for the admin account — reused for the workstation RDP login and the Oracle and PostgreSQL admin accounts; must meet Windows complexity rules
- Enough vCPU quota for the chosen VM sizes in your region. The defaults are `Standard_D4s_v3` (workstation, 4 vCPU) and `Standard_D2s_v3` (Oracle source, 2 vCPU) — 6 vCPU of the **Dsv3** family. If you have no quota, check `az vm list-usage -l <region>` and pass sizes from a family you do have (for example `-p vmSize=Standard_D4s_v5 oracleVmSize=Standard_D2s_v5`)
- A currently deployable Azure OpenAI model in your region. The default is `gpt-5-mini` (`2025-08-07`, `GlobalStandard`). If preflight reports the model is deprecating, list available models with `az cognitiveservices account list-models` and pass `-p openAiModelName=<name> openAiModelVersion=<version>`.

## Access model

The VM is **RDP only, via an Azure Bastion tunnel** — no SSH, no public RDP port, and no
public web ports. RDP (3389) is allowed solely from within the virtual network, so the
only way in is the Bastion tunnel. The login password is set at deploy time
(`adminPassword`); reset it later without a console using `az vm run-command`.

## Deploy

The simplest path is the one-click **Deploy to Azure** button, which opens the Azure
portal with a form for the admin username and password, VM sizes, PostgreSQL tier, and the
model deployment name. No local tooling is required.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2FcreateUiDefinition.json)

To deploy from the command line instead:

```bash
az group create -n oracle-bridge-rg -l westeurope

az deployment group create -g oracle-bridge-rg -f deploy/azure/main.bicep \
  -p adminUsername=azureuser \
     adminPassword='<strong-password>'
```

Outputs include `publicFqdn`, `vmResourceId`, `bastionRdpTunnelCommand`, `oraclePrivateIp`,
`oracleServiceName`, `postgresFqdn`, `postgresAdmin`, `foundryEndpoint`, and
`foundryDeployment`.

## Connect

```bash
# Open an RDP tunnel through Bastion, then RDP to localhost:13389:
az network bastion tunnel -n oracle-bridge-bastion -g oracle-bridge-rg \
  --target-resource-id <vmResourceId> --resource-port 3389 --port 13389
```

RDP to `localhost:13389`, sign in as the workstation user with the password you set,
open Visual Studio Code, run `az login`, then open the **PostgreSQL** extension and start
the **Migration Wizard**.

Use the deployment outputs to fill in the connections. Retrieve them with:

```bash
az deployment group show -g oracle-bridge-rg -n main \
  --query properties.outputs -o json
```

- **Oracle source** — host `oraclePrivateIp`, port 1521, service `oracleServiceName` (`FREEPDB1`), user `system` (or the migration user `mig`), password = the admin password you set.
- **PostgreSQL target** — host `postgresFqdn`, port 5432, admin user `postgresAdmin`, password = the admin password you set. Reachable only from inside the VNet, so connect from the workstation.
- **Azure OpenAI** — endpoint `foundryEndpoint`, deployment `foundryDeployment`; already written to the workstation's environment for the extension.

The Oracle container seeds on first boot and can take several minutes. On the Oracle VM,
`oracle-status` (or the cloud-init log) reports `PROVISION_COMPLETE` when the sample HR
schema is ready.

You need an RDP client: on Windows use the built-in Remote Desktop Connection; on macOS
or Linux install the **Windows App** (formerly Microsoft Remote Desktop). The
`az network bastion tunnel` command requires the Bastion **Standard** SKU with tunneling
enabled — this deployment configures both.

To reset the login password later without a console:

```bash
az vm run-command invoke -g oracle-bridge-rg -n oracle-bridge-vm \
  --command-id RunPowerShellScript \
  --scripts "net user azureuser '<new-password>'"
```

## What you do in the workstation

| Step | In VS Code | Backed by |
|---|---|---|
| 1 Connect to Oracle | Add the Oracle connection in the PostgreSQL extension | The in-lab Oracle source VM (service `FREEPDB1`, port 1521) over the VNet |
| 2 Connect target | Add the PostgreSQL flexible server | The in-lab Azure Database for PostgreSQL server |
| 3 Convert | Run the Migration Wizard | The in-lab Azure OpenAI (Microsoft Foundry) deployment |
| 4 Review | Inspect and refine the generated schema | Copilot Chat |
| 5 Validate | Apply to the PostgreSQL server and verify | PostgreSQL extension |

## Security notes

- No SSH and no public RDP port. The only way in is the Bastion RDP tunnel; RDP (3389) is reachable only from the virtual network.
- The Oracle source (1521) and the PostgreSQL flexible server are reachable only from within the virtual network — no public database endpoints. PostgreSQL uses private access with a private DNS zone.
- No public web ports are opened.
- The login password is supplied at deploy time as a `@secure()` parameter (not stored in the template). It is reused for the Oracle and PostgreSQL admin accounts for lab convenience and is embedded in the Oracle VM's cloud-init custom data — acceptable for a throwaway lab, but rotate/replace it for anything beyond one.
- The workstation has a SystemAssigned managed identity, granted the **Cognitive Services OpenAI User** role on the lab's Azure OpenAI account so the conversion can call the model without keys.
- The `foundryEndpoint`/`foundryDeployment` values are written to machine environment variables as convenience only; the extension still prompts for and manages credentials.

## Tear down

```bash
az group delete -n oracle-bridge-rg --yes
```

The Azure OpenAI account is soft-deleted on group deletion. To free the name and fully
remove it, purge it afterwards:

```bash
az cognitiveservices account purge -n <openai-account-name> -g oracle-bridge-rg -l westeurope
```
