# azure-oracle-pg-migrator

A self-contained **Oracle → Azure Database for PostgreSQL** migration workstation. One Azure VM hosts a guided web wizard plus every CLI the real conversion uses (Oracle Instant Client, `ora2pg`, `psql`, code-server with the PostgreSQL + GitHub Copilot extensions, Azure CLI). Your Oracle schema never leaves the VM.

## What's in this repo

| Path | Purpose |
|---|---|
| [deploy/azure/main.bicep](deploy/azure/main.bicep) | Bicep template — provisions the VM, VNet, NSG, and public IP |
| [deploy/azure/cloud-init.yaml](deploy/azure/cloud-init.yaml) | Installs the full toolchain and starts the web app + code-server |
| [deploy/azure/DEPLOYMENT.md](deploy/azure/DEPLOYMENT.md) | Detailed deployment guide and the 7-step workflow |
| [deploy/azure/schema-conversions-vm-workstation.md](deploy/azure/schema-conversions-vm-workstation.md) | Microsoft Learn-style article describing the VM workstation approach |

## Quick start

```bash
az group create -n oracle-bridge-rg -l westeurope

az deployment group create -g oracle-bridge-rg -f deploy/azure/main.bicep \
  -p adminUsername=azureuser \
     adminLoginPrincipalId="$(az ad signed-in-user show --query id -o tsv)" \
     foundryEndpoint="https://YOUR-FOUNDRY.openai.azure.com" \
     foundryApiKey="$(cat ~/.foundry-key)" \
     foundryDeployment="gpt-5.2" \
     appRepoUrl="https://github.com/Balunywa/azure-oracle-pg-migrator.git" \
     allowedSourceCidr="$(curl -s ifconfig.me)/32"
```

The deployment outputs `webAppUrl`, `codeServer`, `vmResourceId`, and `bastionSshCommand`. While the VM provisions, open `webAppUrl` to watch live install progress. SSH access is via Microsoft Entra ID over Azure Bastion — no SSH keys, no public port 22.

See [deploy/azure/DEPLOYMENT.md](deploy/azure/DEPLOYMENT.md) for prerequisites, first-time wiring, the 7-step workflow, security notes, and tear-down.

## The 7-step flow

| Step | Web UI | Backing tool on the VM |
|---|---|---|
| 1 Intake | Capture source + target metadata | `/etc/oracle-bridge/env` |
| 2 Pre-flight | Static DDL scan | `ora2pg -t SHOW_REPORT` |
| 3 Sample | Validate Oracle reachable | `sqlplus` smoke test |
| 4 Config | Generate `ora2pg.conf` | rendered config |
| 5 Convert | Per-object conversion | `ora2pg -t TABLE/VIEW/...` |
| 6 Review | Diff viewer | code-server + PostgreSQL extension + Copilot |
| 7 Apply | Deploy to Azure PostgreSQL | `psql -f out/*.sql` |

## Security

- SSH is via Microsoft Entra ID over Azure Bastion — no key files, no public port 22; access is RBAC-controlled and audited.
- Lock `allowedSourceCidr` down to your office/VPN range — it defaults to open.
- The VM uses a system-assigned managed identity; grant it only the least-privileged roles it needs.
- Independently validate all converted objects before deploying to production.
