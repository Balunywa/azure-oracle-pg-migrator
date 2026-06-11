# Azure VM deployment — Oracle → Azure PostgreSQL migration workstation

This package provisions a single Azure VM that runs the 7-step web wizard **plus every tool the real conversion uses**, all on private Azure networking. Nothing about your Oracle schema leaves the VM.

## What gets installed on the VM

| Layer | Tool | Purpose |
|---|---|---|
| Web UI | Node 20 + bun, the wizard app, Caddy (auto-HTTPS) | Steps 1–7 in the browser |
| Editor | code-server (browser VS Code) + PostgreSQL extension + GitHub Copilot extensions | Microsoft's official conversion flow |
| Oracle | Oracle Instant Client 21 + `sqlplus` + Perl `DBD::Oracle` | Live read from source Oracle |
| Converter | `ora2pg` 25 | Real schema + data conversion |
| Target | `postgresql-client-16` (`psql`) | Apply to Azure Database for PostgreSQL |
| Cloud | Azure CLI, GitHub CLI | `az login`, `gh auth login` for Copilot |
| LLM | Azure AI Foundry endpoint + key (env vars) | GPT-5.2 backing the conversion |

A helper CLI `oracle-bridge` wraps the 7 steps from the shell:

```
oracle-bridge config          # edit Oracle + Azure PG + Foundry creds
oracle-bridge preflight       # ora2pg SHOW_REPORT against live Oracle
oracle-bridge convert         # export TABLE/SEQ/VIEW/FN/PROC/TRIG/PKG via ora2pg
oracle-bridge apply           # psql the converted DDL into Azure PostgreSQL
oracle-bridge copilot-login   # device-flow GitHub login for Copilot in code-server
```

## Prerequisites

- Azure subscription + `az` CLI logged in
- An SSH public key
- Azure AI Foundry resource with a `gpt-5.2` (or equivalent) deployment — endpoint + key
- Network path from the VM's subnet to your Oracle DB and your Azure Database for PostgreSQL (VNet peering, private endpoint, or VPN). The Bicep creates `10.42.0.0/16` — peer it with whatever holds Oracle.

## Deploy

```bash
az group create -n oracle-bridge-rg -l westeurope

az deployment group create -g oracle-bridge-rg -f deploy/azure/main.bicep \
  -p adminUsername=azureuser \
     sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
     foundryEndpoint="https://YOUR-FOUNDRY.openai.azure.com" \
     foundryApiKey="$(cat ~/.foundry-key)" \
     foundryDeployment="gpt-5.2" \
     appRepoUrl="https://github.com/YOUR-ORG/YOUR-REPO.git" \
     allowedSourceCidr="$(curl -s ifconfig.me)/32"
```

Outputs include `webAppUrl`, `codeServer`, and `sshCommand`.

## First-time wiring (one-shot)

```bash
ssh azureuser@<fqdn>
oracle-bridge config        # paste Oracle DSN/user/pwd + Azure PG host/user/pwd
oracle-bridge preflight     # confirms ora2pg can read Oracle
```

Then open `https://<fqdn>` for the wizard, or `https://<fqdn>:8443` for code-server (password in `/home/azureuser/.config/code-server/config.yaml`). Inside code-server run `oracle-bridge copilot-login` once to enable Copilot.

## What the 7 steps map to

| Step | Web UI does | Backing tool on the VM |
|---|---|---|
| 1 Intake | Capture source + target metadata | written to `/etc/oracle-bridge/env` |
| 2 Pre-flight | Static DDL scan | `ora2pg -t SHOW_REPORT` available too |
| 3 Sample | Validates Oracle DSN reachable | `sqlplus` smoke test |
| 4 Config | Generates `ora2pg.conf` | rendered to `/opt/oracle-bridge/work/ora2pg.conf` |
| 5 Convert | Per-object conversion preview | `ora2pg -t TABLE/VIEW/...` real conversion |
| 6 Review | Diff viewer | code-server with PostgreSQL extension + Copilot |
| 7 Apply | Deploy to Azure PostgreSQL | `psql -f out/*.sql` |

## Security notes

- `allowedSourceCidr` defaults to `*` — **lock it down** to your office / VPN range.
- Foundry key lives in `/etc/oracle-bridge/env` (mode 640, root:root). Rotate by editing and `systemctl restart oracle-bridge-web`.
- The VM has a SystemAssigned managed identity — grant it `Reader` on the Azure PostgreSQL server if you want passwordless `az` flows.
- Caddy uses `tls internal` (self-signed). For a real cert, swap the Caddyfile block for `your.domain.com { reverse_proxy 127.0.0.1:3000 }` and point DNS at the VM's FQDN.

## Tear down

```bash
az group delete -n oracle-bridge-rg --yes
```
