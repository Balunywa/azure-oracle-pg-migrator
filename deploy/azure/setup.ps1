# Provisions a Windows Server 2022 VM as a VNet-integrated workstation for the
# OFFICIAL Oracle -> Azure Database for PostgreSQL schema conversion feature.
#
# Installs desktop Visual Studio Code + the Microsoft PostgreSQL extension
# (ms-ossdata.vscode-pgsql), which runs the Migration Wizard and performs the
# AI conversion via Microsoft Foundry, validated against your scratch database.
# Plus GitHub Copilot, Oracle Instant Client (thick mode), and the Azure CLI.
# No conversion logic runs on this VM; it only hosts VS Code inside the virtual
# network so it can reach a privately networked Oracle source.
#
# Run by an Azure VM Run Command at deploy time. Access is RDP only, over an
# Azure Bastion tunnel. Progress is logged to C:\oracle-workstation-setup.log.

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$log = 'C:\oracle-workstation-setup.log'

function Prog($m) { "$(Get-Date -Format HH:mm:ss) $m" | Tee-Object -FilePath $log -Append }

Prog 'Provisioning the schema conversion workstation...'

# --- Visual Studio Code (desktop, system-wide) -----------------------------
Prog '[1/4] Installing Visual Studio Code...'
$vscode = "$env:TEMP\vscode-setup.exe"
Invoke-WebRequest -Uri 'https://update.code.visualstudio.com/latest/win32-x64/stable' -OutFile $vscode
Start-Process -Wait -FilePath $vscode -ArgumentList '/VERYSILENT','/NORESTART','/MERGETASKS=!runcode,addtopath'

# --- PostgreSQL extension + GitHub Copilot ---------------------------------
# Extensions are per-user, so install them at the first interactive logon via
# a machine RunOnce entry (code is on the machine PATH after the system install).
Prog '[2/4] Queuing PostgreSQL extension + GitHub Copilot for first logon...'
$extCmd = 'code --install-extension ms-ossdata.vscode-pgsql && ' +
          'code --install-extension github.copilot && ' +
          'code --install-extension github.copilot-chat'
$runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
New-Item -Path $runOnce -Force | Out-Null
Set-ItemProperty -Path $runOnce -Name 'InstallVSCodeExtensions' -Value "cmd /c $extCmd"

# --- Oracle Instant Client 21 (thick client mode) --------------------------
Prog '[3/4] Installing Oracle Instant Client 21 (thick client mode)...'
$oraZip = "$env:TEMP\instantclient.zip"
Invoke-WebRequest -Uri 'https://download.oracle.com/otn_software/nt/instantclient/2113000/instantclient-basic-windows.x64-21.13.0.0.0dbru.zip' -OutFile $oraZip
Expand-Archive -Path $oraZip -DestinationPath 'C:\oracle' -Force
$ic = (Get-ChildItem 'C:\oracle' -Directory | Where-Object { $_.Name -like 'instantclient*' } | Select-Object -First 1).FullName
if ($ic) {
  $machinePath = [Environment]::GetEnvironmentVariable('PATH','Machine')
  [Environment]::SetEnvironmentVariable('PATH', "$machinePath;$ic", 'Machine')
}

# --- Azure CLI (Microsoft Entra ID sign-in for Foundry / target DB) --------
Prog '[4/4] Installing Azure CLI...'
$azMsi = "$env:TEMP\azure-cli.msi"
Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindows' -OutFile $azMsi
Start-Process -Wait -FilePath 'msiexec.exe' -ArgumentList '/i',"$azMsi",'/qn','/norestart'

# --- Foundry convenience values (the extension also prompts for these) -----
[Environment]::SetEnvironmentVariable('FOUNDRY_ENDPOINT',   '__FOUNDRY_ENDPOINT__',   'Machine')
[Environment]::SetEnvironmentVariable('FOUNDRY_DEPLOYMENT', '__FOUNDRY_DEPLOYMENT__', 'Machine')

Prog 'PROVISION_COMPLETE - VS Code + PostgreSQL extension ready.'
Prog 'Connect over a Bastion RDP tunnel, then open VS Code and start the Migration Wizard.'
