param(
  [Parameter(Mandatory = $true)]
  [string]$Name,

  [string]$User        = $env:USERNAME,
  [int]$Port           = 2222,
  [string]$DgxHost     = 'spark-79b7.local',
  [string]$SmbPassword = ''
)

$ErrorActionPreference = 'Stop'

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "WARN: $m" -ForegroundColor Yellow }

# -----------------------------------------------------------------------
# Pre-flight: purge stale CIFS fstab entries (legacy cleanup).
# Use EAP=Continue — distro may not be running and starting it emits
# fstab warnings that are deferred NativeCommandErrors under EAP=Stop.
# -----------------------------------------------------------------------
Write-Host 'Pre-flight: clearing stale fstab entries...'
$_pref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& wsl.exe -d $Name -u root -- bash -c "sed -i '\|$DgxHost/shared|d' /etc/fstab 2>/dev/null; true" 2>$null
& wsl.exe --terminate $Name 2>$null
$ErrorActionPreference = $_pref
Write-Host 'Pre-flight: done'

# Run a multi-line bash script inside a distro without CRLF injection.
# base64-encodes the script; bash decodes and pipes to bash -s inside Linux.
# Extra positional args are forwarded as $1, $2, ...
function Invoke-WslBash {
  param(
    [string]$WslDistro,
    [string]$WslUser,
    [string]$Script
  )
  $scriptClean = $Script -replace "`r", ""
  $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($scriptClean)
  $b64 = [Convert]::ToBase64String($scriptBytes)
  $shellArgs = if ($args.Count -gt 0) {
    ' -- ' + (($args | ForEach-Object { "'$_'" }) -join ' ')
  } else { '' }
  & wsl.exe -d $WslDistro -u $WslUser -- bash -c "echo '$b64' | base64 -d | bash -s$shellArgs"
  if ($LASTEXITCODE -ne 0) { throw "Bash script failed (exit $LASTEXITCODE)" }
}

# -----------------------------------------------------------------------
# Step 1: .wslconfig (mirrored networking)
# -----------------------------------------------------------------------
Step '.wslconfig (mirrored networking)'
$wslcfgPath = Join-Path $env:USERPROFILE '.wslconfig'
$wslcfgWant = @"
[wsl2]
networkingMode=mirrored
dnsTunneling=true
firewall=true
"@

$needsShutdown = $false
if (Test-Path $wslcfgPath) {
  $existing = Get-Content $wslcfgPath -Raw -ErrorAction SilentlyContinue
  if ($existing.Trim() -ne $wslcfgWant.Trim()) {
    Set-Content $wslcfgPath $wslcfgWant -Encoding UTF8
    $needsShutdown = $true
    Write-Host 'Updated .wslconfig'
  } else {
    Write-Host '.wslconfig already correct'
  }
} else {
  Set-Content $wslcfgPath $wslcfgWant -Encoding UTF8
  $needsShutdown = $true
  Write-Host 'Created .wslconfig'
}
if ($needsShutdown) {
  Write-Host 'Running wsl --shutdown to apply .wslconfig...'
  & wsl.exe --shutdown
  Start-Sleep -Seconds 3
}

# -----------------------------------------------------------------------
# Step 2: Windows Firewall rule for sshd port
# -----------------------------------------------------------------------
$fwRuleName = "WSL2 SSH $Port Inbound"
Step "Firewall rule: $fwRuleName"
if (Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue) {
  Write-Host 'Rule already exists'
} else {
  New-NetFirewallRule `
    -DisplayName $fwRuleName `
    -Direction   Inbound `
    -Protocol    TCP `
    -LocalPort   $Port `
    -Action      Allow | Out-Null
  Write-Host "Firewall rule created"
}

# -----------------------------------------------------------------------
# Step 3: sshd port inside the distro
# Single-quoted here-string avoids CRLF injection via Invoke-WslBash.
# -----------------------------------------------------------------------
Step "sshd port $Port in distro '$Name'"
$sshdScript = @'
apt-get install -y --no-install-recommends openssh-server 2>&1 | tail -3
mkdir -p /etc/ssh/sshd_config.d
printf 'Port %s\n' "$1" > /etc/ssh/sshd_config.d/wsl2-port.conf
service ssh restart || service sshd restart || true
'@
Invoke-WslBash $Name root $sshdScript "$Port"

# -----------------------------------------------------------------------
# Step 4: SSH key (ensure exists) and read pubkey
# -----------------------------------------------------------------------
Step "SSH key in distro '$Name'"
$keyScript = @'
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "${USER}@wsl2" -N ""
  chmod 600 ~/.ssh/id_ed25519 && chmod 644 ~/.ssh/id_ed25519.pub
  echo "SSH key generated"
else
  echo "SSH key already exists"
fi
'@
Invoke-WslBash $Name $User $keyScript
$wsl2PubKey = (& wsl.exe -d $Name -u $User -- cat "/home/$User/.ssh/id_ed25519.pub" 2>$null)
if (-not $wsl2PubKey) { throw "Could not read WSL2 pubkey from distro '$Name'" }
$wsl2PubKey = $wsl2PubKey.Trim()
Write-Host "WSL2 pubkey: $wsl2PubKey"

# -----------------------------------------------------------------------
# Step 5: SSH mesh bootstrap (smbclient-based, no CIFS mount)
# -----------------------------------------------------------------------
if (-not $SmbPassword) {
  Warn 'SmbPassword not provided -- skipping SSH mesh setup'
} else {

  Step "Write .smbcredentials in distro '$Name'"
  # Pipe via stdin to keep password out of process args.
  "username=$User`npassword=$SmbPassword" | & wsl.exe -d $Name -u $User -- `
    bash -c 'cat > ~/.smbcredentials && chmod 600 ~/.smbcredentials'
  Write-Host '.smbcredentials written'

  Step "Write /etc/wsl2-distro-name in distro '$Name'"
  & wsl.exe -d $Name -u root -- bash -c "echo '$Name' > /etc/wsl2-distro-name"
  Write-Host "/etc/wsl2-distro-name = $Name"

  # setup-shared-ssh.sh was SCP'd to %USERPROFILE% by the workflow.
  $setupScript = "$env:USERPROFILE\setup-shared-ssh.sh"
  if (-not (Test-Path $setupScript)) {
    throw "setup-shared-ssh.sh not found at $setupScript"
  }
  $setupSh = Get-Content $setupScript -Raw

  # Install to /usr/local/bin/ so the systemd service can use it on future boots.
  Step "Install setup-shared-ssh.sh in distro '$Name'"
  $installScript = @'
set -euo pipefail
echo "$1" | base64 -d > /usr/local/bin/setup-shared-ssh.sh
chmod 755 /usr/local/bin/setup-shared-ssh.sh
echo "installed"
'@
  $scriptB64 = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes(($setupSh -replace "`r", ""))
  )
  Invoke-WslBash $Name root $installScript $scriptB64

  # Enable the systemd service for future cold starts.
  $svcScript = @'
set -euo pipefail
USER_ARG="$1"
tee /etc/systemd/system/wsl2-ssh-setup.service >/dev/null <<EOF
[Unit]
Description=Sync SSH mesh files from DGX shared store (smbclient)
After=avahi-daemon.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-shared-ssh.sh spark-79b7.local ${USER_ARG}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable wsl2-ssh-setup.service
echo "wsl2-ssh-setup.service enabled"
'@
  Invoke-WslBash $Name root $svcScript $User

  # Run setup-shared-ssh.sh now to do the initial sync.
  Step "Run setup-shared-ssh.sh in distro '$Name'"
  Invoke-WslBash $Name root $setupSh $DgxHost $User $Name "$Port"
  Write-Host 'SSH mesh setup complete'
}

# -----------------------------------------------------------------------
# Output -- single tagged line captured by GHA
# -----------------------------------------------------------------------
Write-Host ''
Write-Host "WSL2_PUBKEY=$wsl2PubKey"
