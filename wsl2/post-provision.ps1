param(
  [Parameter(Mandatory = $true)]
  [string]$Name,

  [string]$User           = $env:USERNAME,
  [int]$Port              = 2222,
  [string]$DgxHost        = 'spark-79b7.local',
  [string]$DgxSmbPassword = ''
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
# Step 4: Write distro name + mount DGX shared store + symlink ~/.ssh/
# setup-shared-ssh.sh (installed by bootstrap.sh) mounts //DGX/shared
# via CIFS and symlinks ~/.ssh/ to ~/shared/ssh/ — all distros share
# Spark's SSH identity. ~/.smbcredentials is baked into the template.
# -----------------------------------------------------------------------
Step "Write /etc/wsl2-distro-name in distro '$Name'"
& wsl.exe -d $Name -u root -- bash -c "echo '$Name' > /etc/wsl2-distro-name"
Write-Host "/etc/wsl2-distro-name = $Name"

Step "Mount DGX shared store and join SSH mesh in distro '$Name'"
$setupScript = @"
set -euo pipefail
/usr/local/bin/setup-shared-ssh.sh $DgxHost $User $Name $Port
"@
Invoke-WslBash $Name root $setupScript
Write-Host 'SSH mesh join complete'

$wsl2PubKey = (& wsl.exe -d $Name -u $User -- cat "/home/$User/.ssh/id_ed25519.pub" 2>`$null)
if (-not $wsl2PubKey) { throw "Could not read pubkey from distro '$Name' after SSH mesh join" }
$wsl2PubKey = $wsl2PubKey.Trim()
Write-Host "Pubkey: $wsl2PubKey"

# -----------------------------------------------------------------------
# Output -- single tagged line captured by GHA
# -----------------------------------------------------------------------
Write-Host ''
Write-Host "WSL2_PUBKEY=$wsl2PubKey"
