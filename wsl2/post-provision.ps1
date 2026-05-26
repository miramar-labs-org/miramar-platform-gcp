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

# Run a multi-line bash script inside a distro without CRLF injection.
# base64-encodes the script in PowerShell; bash decodes inside Linux.
# Extra positional args forwarded as $1, $2, ...
function Invoke-WslBash {
  param([string]$WslDistro, [string]$WslUser, [string]$Script)
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
# Pre-flight: clear any stale fstab entries from old CIFS-based approach.
# Use EAP=Continue -- distro may not be running yet and starting it can
# emit fstab warnings that become deferred NativeCommandErrors under Stop.
# -----------------------------------------------------------------------
Write-Host 'Pre-flight: clearing stale fstab entries...'
$_pref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& wsl.exe -d $Name -u root -- bash -c "sed -i '\|$DgxHost/shared|d' /etc/fstab 2>/dev/null; true" 2>$null
& wsl.exe --terminate $Name 2>$null
$ErrorActionPreference = $_pref
Write-Host 'Pre-flight: done'

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
  Write-Host 'Applying .wslconfig (wsl --shutdown)...'
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
    -DisplayName $fwRuleName -Direction Inbound `
    -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
  Write-Host "Firewall rule created"
}

# -----------------------------------------------------------------------
# Step 3: sshd port inside the distro
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
# Step 4: Ensure SSH key exists; read pubkey
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
if (-not $wsl2PubKey) { throw "Could not read pubkey from distro '$Name'" }
$wsl2PubKey = $wsl2PubKey.Trim()
Write-Host "Pubkey: $wsl2PubKey"

# -----------------------------------------------------------------------
# Step 5: Deliver credentials + trigger first-launch SSH mesh join.
# The template has wsl2-ssh-setup.service pre-installed (bootstrap.sh).
# PowerShell only delivers the two things only it knows: the Samba
# password and the distro name. The service does the rest on its own.
# -----------------------------------------------------------------------
if (-not $SmbPassword) {
  Warn 'SmbPassword not provided -- skipping SSH mesh setup'
} else {

  Step "Write .smbcredentials in distro '$Name'"
  # Pipe via stdin -- keeps password out of process args.
  # tr -d '\r' strips CRLF that PowerShell's | pipe adds on Windows.
  "username=$User`npassword=$SmbPassword" | & wsl.exe -d $Name -u $User -- `
    bash -c 'tr -d "\r" > ~/.smbcredentials && chmod 600 ~/.smbcredentials'
  Write-Host '.smbcredentials written'

  Step "Write /etc/wsl2-distro-name in distro '$Name'"
  & wsl.exe -d $Name -u root -- bash -c "echo '$Name' > /etc/wsl2-distro-name"
  Write-Host "/etc/wsl2-distro-name = $Name"

  # Trigger the service and wait for it to complete (up to 2 minutes).
  # The service was enabled by bootstrap.sh; on cold start it runs
  # setup-shared-ssh.sh which syncs SSH files from DGX via smbclient.
  Step "Trigger wsl2-ssh-setup.service in distro '$Name'"
  $svcScript = @'
set -euo pipefail
systemctl start wsl2-ssh-setup.service
for i in $(seq 1 24); do
  STATUS=$(systemctl is-active wsl2-ssh-setup 2>/dev/null || echo unknown)
  echo "  wsl2-ssh-setup: $STATUS ($i/24)"
  [[ "$STATUS" == "active" ]] && exit 0
  [[ "$STATUS" == "failed" ]] && { journalctl -u wsl2-ssh-setup --no-pager -n 20; exit 1; }
  sleep 5
done
echo "WARN: service did not complete within 120s"
journalctl -u wsl2-ssh-setup --no-pager -n 20
'@
  Invoke-WslBash $Name root $svcScript
  Write-Host 'SSH mesh join complete'
}

# -----------------------------------------------------------------------
# Output -- single tagged line captured by GHA
# -----------------------------------------------------------------------
Write-Host ''
Write-Host "WSL2_PUBKEY=$wsl2PubKey"
