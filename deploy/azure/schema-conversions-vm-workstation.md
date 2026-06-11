---
title: Run schema conversion on a dedicated Azure VM workstation
description: Provision a self-contained Azure virtual machine that runs the full Oracle to Azure Database for PostgreSQL schema conversion toolchain on private Azure networking.
ms.topic: how-to
---

# Run schema conversion on a dedicated Azure VM workstation

For migrations where the source Oracle database is reachable only from inside a
private network, or where security policy requires that schema and credentials
never leave a controlled environment, you can run the entire schema conversion
workflow on a single, dedicated Azure virtual machine. The VM hosts the Visual
Studio Code PostgreSQL extension and every supporting command-line tool the
conversion uses, so the source schema is read, transformed, validated, and
applied without leaving Azure.

This approach complements the standard local Visual Studio Code workflow. Use it
when you need a reproducible, network-isolated workstation rather than a developer
laptop with direct line of sight to both Oracle and Azure Database for PostgreSQL
flexible server.

## Architecture

The workstation packages the conversion components onto one Ubuntu virtual
machine that sits inside a virtual network you control:

- **Source Oracle database**: Reached over private networking (virtual network peering, private endpoint, or VPN) from the VM's subnet.
- **Conversion VM**: An Azure virtual machine that runs the PostgreSQL extension in browser-hosted Visual Studio Code, plus the Oracle and PostgreSQL clients and the conversion engine.
- **Azure Database for PostgreSQL flexible server**: Hosts the scratch schemas used for validation and the final target database.
- **Microsoft Foundry**: Provides the language models that power AI-driven schema transformation, reached over a private endpoint.
- **GitHub Copilot agent mode**: Runs inside the browser-hosted editor to help resolve review tasks.

## What gets installed on the VM

The VM is provisioned from cloud-init so the toolchain is identical on every
deployment:

| Layer | Tool | Purpose |
|---|---|---|
| Editor | Browser-hosted Visual Studio Code, PostgreSQL extension, GitHub Copilot extensions | The Microsoft schema conversion workflow |
| Oracle connectivity | Oracle Instant Client and `sqlplus` | Read schema objects from the source Oracle database |
| PostgreSQL connectivity | `psql` (PostgreSQL client) | Apply converted objects to Azure Database for PostgreSQL flexible server |
| Cloud and identity | Azure CLI, GitHub CLI | `az` sign-in for Azure resources and `gh` sign-in for Copilot |
| Language models | Microsoft Foundry endpoint and credentials (environment variables) | Backs AI-driven schema transformation |
| Web front end | Node.js runtime and reverse proxy with automatic HTTPS | Optional guided wizard for the conversion steps |

> [!NOTE]
> Oracle Instant Client enables thick client mode. Install it when your source
> Oracle environment requires native network encryption. For details, see
> [Oracle connectivity modes](schema-conversions-overview.md#oracle-connectivity-modes).

## How it works

The VM-hosted flow follows the same intelligent, multistage approach as the
standard workflow, with each stage running inside the isolated environment:

- **Connection and discovery**: The PostgreSQL extension connects to the source Oracle database over private networking and catalogs the schema objects.
- **AI-powered transformation**: Schema conversion agents call language models in Microsoft Foundry over a private endpoint to transform Oracle constructs into PostgreSQL-compatible equivalents.
- **Validation in scratch schemas**: Converted objects are tested against scratch schemas on the Azure Database for PostgreSQL flexible server you designate.
- **Review and guided resolution**: GitHub Copilot agent mode runs in the browser-hosted editor on the VM to help complete flagged review tasks.
- **Output and apply**: Validated objects are written as PostgreSQL `.sql` files and applied to the target database with `psql`, all from within the VM.

## Deploy the workstation

You deploy the VM with an Azure Resource Manager template (Bicep). The deployment
creates the virtual network, network security group, public IP, and VM, and runs
cloud-init to install the toolchain.

### Prerequisites

- An Azure subscription with the Azure CLI installed and signed in.
- An SSH public key for the VM administrator account.
- A Microsoft Foundry resource with a model deployment (endpoint and credentials).
- A network path from the VM's subnet to both the source Oracle database and the target Azure Database for PostgreSQL flexible server.

### Deployment steps

1. Create a resource group:

   ```bash
   az group create --name <resource-group> --location <region>
   ```

1. Deploy the template, supplying your SSH key, Foundry endpoint, and the CIDR range allowed to reach the VM:

   ```bash
   az deployment group create \
     --resource-group <resource-group> \
     --template-file main.bicep \
     --parameters adminUsername=<admin-user> \
                  sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
                  foundryEndpoint="https://<resource>.openai.azure.com" \
                  foundryDeployment="<deployment-name>" \
                  allowedSourceCidr="<your-ip>/32"
   ```

1. After the deployment finishes, use the template outputs to reach the workstation: the web wizard URL, the browser-hosted editor URL, and the SSH command.

> [!IMPORTANT]
> The `allowedSourceCidr` parameter controls who can reach the VM. Restrict it to
> your office or VPN range. Don't leave it open to the internet.

## Security and networking

Run the workstation under the same security principles as the standard workflow,
and take advantage of the isolated VM to keep schema and credentials inside your
Azure boundary:

- **Private endpoints**: Connect to Microsoft Foundry by using a private endpoint. For more information, see [Configure a private link for Microsoft Foundry](/azure/ai-foundry/how-to/configure-private-link).
- **Credential storage**: Foundry and database credentials are stored in a root-owned environment file with restricted permissions. Rotate them by updating the file and restarting the service.
- **Managed identity**: The VM uses a system-assigned managed identity. Grant it the least-privileged role it needs on your Azure resources to enable passwordless access where possible.
- **Transport security**: The reverse proxy uses HTTPS. For a trusted certificate, point a DNS name at the VM and configure the proxy for that hostname.
- **Customer validation responsibility**: As with any AI-assisted conversion, independently validate all converted objects and review-task resolutions before you deploy to production.

## Tear down

When the migration is complete, delete the resource group to remove the VM and
all associated networking resources:

```bash
az group delete --name <resource-group> --yes
```

## Related content

- [What is Oracle to Azure Database for PostgreSQL schema conversion?](schema-conversions-overview.md)
- [Best practices for Oracle to Azure Database for PostgreSQL schema conversion](schema-conversions-best-practices.md)
- [Review tasks and output folders for Oracle to Azure Database for PostgreSQL schema conversion](schema-conversions-review-tasks-artifacts.md)
- [Schema conversion limitations](schema-conversions-limitations.md)
