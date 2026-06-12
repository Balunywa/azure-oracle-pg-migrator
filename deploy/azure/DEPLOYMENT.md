# Azure VM deployment — schema conversion workstation

This package provisions a single Azure VM as a **VNet-integrated workstation** for the
official Oracle → Azure Database for PostgreSQL schema conversion feature. The VM runs
**desktop Visual Studio Code + the Microsoft PostgreSQL extension**, which performs the
AI conversion through **Microsoft Foundry** and validates it against a **scratch Azure
Database for PostgreSQL** server — exactly the local workflow, but inside the virtual
network so it can reach a privately networked Oracle source.

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
| Desktop | XFCE + xrdp | GUI for VS Code, reached privately over Bastion (RDP) |

Provisioning progress is logged to `/var/log/oracle-workstation-setup.log`. Run
`workstation-status` over SSH to follow it until `PROVISION_COMPLETE`.

## Prerequisites

- Azure subscription + `az` CLI logged in
- Permission to assign roles, and your own object ID (`az ad signed-in-user show --query id -o tsv`) for Entra ID VM login
- A Microsoft Foundry resource + model deployment for the conversion (the extension prompts for the endpoint/deployment)
- A scratch Azure Database for PostgreSQL flexible server the extension can validate against
- Network path from the VM's subnet to your Oracle DB (VNet peering, private endpoint, or VPN). The Bicep creates `10.42.0.0/16` — peer it with whatever holds Oracle.

## Access model

The VM uses **Microsoft Entra ID SSH login over Azure Bastion** — no SSH key files and no
public port 22. The desktop is reached over **Bastion RDP** (port 3389 allowed only from
within the virtual network). Access is controlled by Azure RBAC (the *Virtual Machine
Administrator Login* role) and is fully audited. An SSH key is optional (`sshPublicKey`)
as a break-glass fallback.

## Deploy

```bash
az group create -n oracle-bridge-rg -l westeurope

az deployment group create -g oracle-bridge-rg -f deploy/azure/main.bicep \
  -p adminUsername=azureuser \
     adminLoginPrincipalId="$(az ad signed-in-user show --query id -o tsv)" \
     foundryEndpoint="https://YOUR-FOUNDRY.openai.azure.com" \
     foundryDeployment="gpt-5.2"
```

Outputs include `publicFqdn`, `vmResourceId`, `bastionSshCommand`, and `bastionRdpTunnelCommand`.

## Connect

```bash
# 1. SSH over Bastion with your Entra ID identity (no key files):
az network bastion ssh -n oracle-bridge-bastion -g oracle-bridge-rg \
  --target-resource-id <vmResourceId> --auth-type AAD --username <you@domain>

# Watch provisioning finish, then set a desktop password for RDP:
workstation-status
sudo passwd $USER

# 2. Open an RDP tunnel through Bastion, then RDP to localhost:13389:
az network bastion tunnel -n oracle-bridge-bastion -g oracle-bridge-rg \
  --target-resource-id <vmResourceId> --resource-port 3389 --port 13389
```

In the RDP desktop, sign in to the workstation user, open Visual Studio Code, run
`az login`, then open the **PostgreSQL** extension and start the **Migration Wizard**.

## What you do in the workstation

| Step | In VS Code | Backed by |
|---|---|---|
| 1 Connect to Oracle | Add the Oracle connection in the PostgreSQL extension | Oracle Instant Client (thick mode) over the VNet |
| 2 Connect target | Add the scratch Azure Database for PostgreSQL server | Azure CLI / Entra ID |
| 3 Convert | Run the Migration Wizard | Microsoft Foundry deployment |
| 4 Review | Inspect and refine the generated schema | Copilot Chat |
| 5 Validate | Apply to the scratch database and verify | PostgreSQL extension |

## Security notes

- SSH access is via Microsoft Entra ID over Azure Bastion — no public port 22 and no key files. Grant access by assigning the *Virtual Machine Administrator Login* role; revoke centrally in Azure.
- No public web ports are opened. RDP (3389) is reachable only from the virtual network, via the Bastion tunnel.
- The desktop RDP password is set by you over SSH (`sudo passwd $USER`); no secret is baked into the template.
- The VM has a SystemAssigned managed identity — grant it the roles you need for passwordless `az` flows against the scratch database.
- The `foundryEndpoint`/`foundryDeployment` values are written to `/etc/oracle-workstation/env` as convenience only; the extension still prompts for and manages credentials.

## Tear down

```bash
az group delete -n oracle-bridge-rg --yes
```
