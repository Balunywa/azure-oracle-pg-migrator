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
password, VM sizes, PostgreSQL tier, an optional Microsoft Entra admin for the PostgreSQL
server, and model deployment name), and select **Review + create**. Everything — workstation,
Oracle source, PostgreSQL target, and the Azure OpenAI deployment — is created for you. No
CLI required.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-oracle-pg-migrator%2Fmain%2Fdeploy%2Fazure%2Fazuredeploy.json)

After the deployment finishes, see [Connect to the workstation](deploy/azure/DEPLOYMENT.md#connect)
to open the Azure Bastion RDP tunnel and start the Migration Wizard.

## What's installed on the workstation

The workstation is a Windows Server 2022 VM provisioned at deploy time by
[deploy/azure/setup.ps1](deploy/azure/setup.ps1).

**VS Code extensions** (installed at first interactive logon):

| Extension | ID | Purpose |
|---|---|---|
| PostgreSQL (Microsoft) | `ms-ossdata.vscode-pgsql` | Runs the Migration Wizard and performs the AI schema conversion |
| GitHub Copilot | `github.copilot` | Copilot agent used to triage and fix conversion tasks |
| GitHub Copilot Chat | `github.copilot-chat` | Chat / agent mode for resolving flagged items |

**Command-line tooling** (installed system-wide during deployment):

- **Visual Studio Code** (desktop, added to `PATH`)
- **Oracle Instant Client 21.13** (thick-client mode, on `PATH`) — connects to the Oracle source
- **Azure CLI** — Microsoft Entra ID sign-in for Foundry and the PostgreSQL target

> **First-logon note:** the three extensions install via a Windows `RunOnce` entry the first
> time you sign in, so they need outbound access to the VS Code Marketplace at that moment and
> appear a few seconds after the desktop loads. The setup log's `PROVISION_COMPLETE` line is
> written *before* that logon, so it confirms the deploy-time steps finished — not that the
> extensions installed. If any are missing, run the `code --install-extension` commands from
> [deploy/azure/setup.ps1](deploy/azure/setup.ps1) manually in a terminal.

## After deployment: run the schema conversion

The template stands up the whole environment, but the conversion itself is an **interactive**
task you run inside VS Code on the workstation — the Migration Wizard and GitHub Copilot
can't run headlessly. Follow these steps once the deployment finishes.

### 1. Collect your connection values

Every value the wizard asks for is a deployment output. Open the deployment's **Outputs**
in the portal, or run:

```bash
az deployment group show -g oracle-bridge-rg -n <deployment-name> \
  --query properties.outputs -o jsonc
```

| Wizard field | Value | Output |
|---|---|---|
| Oracle host | e.g. `10.42.3.4` | `oraclePrivateIp` |
| Oracle port | `1521` | (fixed) |
| Oracle service name | `FREEPDB1` | `oracleServiceName` |
| Oracle migration user | `MIG` + your deploy password | seeded, read-only |
| PostgreSQL server | e.g. `orabridge-pg-xxxx.postgres.database.azure.com` | `postgresFqdn` |
| PostgreSQL admin | `azureuser` + your deploy password | `postgresAdmin` |
| PostgreSQL Entra admin | tokenless sign-in via Browse Azure (only if you set one) | `postgresEntraAdmin` |
| Foundry endpoint | e.g. `https://orabridge-oai-xxxx.openai.azure.com/` | `foundryEndpoint` |
| Foundry deployment | `gpt-5-mini` | `foundryDeployment` |

The Foundry endpoint and deployment are also set on the workstation as the machine
environment variables `FOUNDRY_ENDPOINT` and `FOUNDRY_DEPLOYMENT`.

### 2. Connect and sign in

1. Open the Bastion RDP tunnel (the `bastionRdpTunnelCommand` output) and RDP to
   `localhost:13389` with your admin username and password.
2. Launch **Visual Studio Code**. On first logon the PostgreSQL extension, GitHub Copilot,
   and Copilot Chat finish installing.
3. Sign in to **GitHub Copilot** and to the **PostgreSQL extension** (Microsoft Entra ID).
   This is the one sign-in the template can't do for you.

### 3. Create the migration project

In the PostgreSQL extension, open the **Migrations (preview)** view → **Create Migration Project**:

1. **Project Setup** — name the project, then **Next**.
2. **Connect to Oracle** — host `oraclePrivateIp`, port `1521`, service `FREEPDB1`, user
   `MIG` with your deploy password. Select **Load Schemas**, choose **HR**, then **Next**.
3. **Scratch database** — connect to the PostgreSQL flexible server (`postgresFqdn`). If you
   set a Microsoft Entra admin at deploy time (`entraAdminObjectId`), choose **Browse Azure**
   and select the server with **Microsoft Entra ID** authentication — no password to enter or
   store. Otherwise connect with admin `azureuser` and your deploy password. Pick a target
   database, select **Verify Extensions**, then **Next**.
4. **Microsoft Foundry** — enter `foundryEndpoint` and the deployment name `gpt-5-mini`,
   and choose **Microsoft Entra ID** for authentication.
5. Select **Test Connection**, then **Create Migration Project**.

### 4. Run the conversion

On the **Schema Migration** card select **Migrate**, watch the *Extracting → Converting*
stages, and wait for **Migration Complete**. Select **View Migration Report**.

### 5. Review, triage, and resolve

1. Read `reports/customer_summary.md` first for the readiness decision, success percentage,
   and the count of **Mandatory** tasks. For a per-object breakdown with DDL snippets, open
   `reports/technical_conversion_report.md`; treat `reports/review_tasks.md` as an offline
   reference and resolve tasks from the Schema Review pane instead.
2. In the **Schema Review** pane, start in the **Grouped** view to scan tasks by behavioral
   category (for example *Numeric Semantics*, *Empty String / NULL*), then switch to the
   **Tasks** view and filter **Status = Pending**, **Priority = Mandatory** to work through
   them one by one.
3. Select **Run Task** to open **GitHub Copilot agent mode** with the source and generated
   DDL loaded. Review the proposed fix, apply it to the `.sql` file under
   `postgres_ddl/<schema>/<object_type>/`, run it against the scratch database to confirm it
   compiles, then select **Resolve**.
4. Independently validate every AI-assisted fix — the success percentage reflects automated
   coverage, not deployment readiness.

### 6. Produce and deploy `deploy.sql`

The consolidated `deploy.sql` under
`artifacts/oracle/_migration/convert/sessions/<session-id>/` creates the target schema in
dependency order. After you fix the root cause of a task, **rerun the conversion** so
`deploy.sql` is regenerated (a change made directly against the scratch database is *not*
propagated), then apply `deploy.sql` to the PostgreSQL server.

> **If "Verify Extensions" fails:** Azure Database for PostgreSQL requires extensions to be
> allow-listed before use. Add the ones your schema needs to the `azure.extensions` server
> parameter (the server's **Server parameters** blade) and retry.
>
> **If "Load Schemas" fails with a permission error on `SYS.ARGUMENT$`:** the migration user
> needs dictionary read access. Connect as a privileged user and run
> `GRANT SELECT ANY DICTIONARY TO MIG;` (new deployments already include this grant).

## Tear down

When you're done, remove everything by deleting the resource group. Azure has no native
one-click *delete* URL (by design), so this button opens the **Resource groups** blade in
the portal — pick the lab's group (for example `oracle-bridge-rg`) and choose
**Delete resource group**:

[![Delete resources](https://img.shields.io/badge/Delete-resource%20group-critical?style=for-the-badge&logo=microsoftazure&logoColor=white)](https://portal.azure.com/#browse/resourcegroups)

Or run the teardown script (deletes the group and purges the soft-deleted Azure OpenAI
account so its name is freed):

```bash
./deploy/azure/teardown.sh oracle-bridge-rg
```

Equivalent one-liner:

```bash
az group delete -n oracle-bridge-rg --yes
```

## What's in this repo

| Path | Purpose |
|---|---|
| [deploy/azure/azuredeploy.json](deploy/azure/azuredeploy.json) | Compiled ARM template behind the **Deploy to Azure** button |
| [deploy/azure/createUiDefinition.json](deploy/azure/createUiDefinition.json) | Portal form definition for the one-click deployment |
| [deploy/azure/main.bicep](deploy/azure/main.bicep) | Bicep source — provisions the whole lab: VNet/NSG/Bastion, the Windows workstation, the Oracle source VM, the PostgreSQL flexible server, and the Azure OpenAI deployment |
| [deploy/azure/setup.ps1](deploy/azure/setup.ps1) | PowerShell run by an Azure Run Command — installs VS Code + PostgreSQL extension + Oracle Instant Client + Azure CLI on the workstation |
| [deploy/azure/teardown.sh](deploy/azure/teardown.sh) | Deletes the resource group and purges the soft-deleted Azure OpenAI account |
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

## Security

- RDP only, via an Azure Bastion tunnel — no SSH, no public RDP port; RDP (3389) is reachable only from the virtual network.
- The Oracle source (1521) and the PostgreSQL flexible server are reachable **only from within the virtual network** — no public database endpoints. PostgreSQL uses private access with a private DNS zone.
- No public web ports.
- The login password is a `@secure()` deploy-time parameter (not stored in the template) and can be rotated with `az vm run-command`. It is reused for the Oracle and PostgreSQL admin accounts for lab convenience — change them for anything beyond a lab.
- The workstation uses a system-assigned managed identity, granted only the **Cognitive Services OpenAI User** role on the lab's Azure OpenAI account.
- Independently validate all converted objects before deploying to production.
