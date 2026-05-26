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
# Pre-flight: purge any stale CIFS fstab entry from a previous run.
# A CIFS entry without 'nofail' causes WSL2 to write
# "Processing /etc/fstab with mount -a failed." to stderr on every cold
# start. Under ErrorActionPreference=Stop that NativeCommandError is
# deferred to the NEXT statement in the caller scope, silently killing the
# script at an unrelated line. Remove it now; setup-shared-ssh.sh re-adds
# it with nofail.
# Use ErrorActionPreference=Continue here -- the distro may not be running
# yet, and starting it will itself trigger the fstab message we're fixing.
# -----------------------------------------------------------------------
Write-Host 'Pre-flight: clearing stale CIFS fstab entries...'
$_pref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& wsl.exe -d $Name -u root -- bash -c "sed -i '\|$DgxHost/shared|d' /etc/fstab 2>/dev/null; true" 2>$null
& wsl.exe --terminate $Name 2>$null
$ErrorActionPreference = $_pref
Write-Host 'Pre-flight: done'

# Run a multi-line bash script inside a distro without CRLF injection.
# PowerShell's | pipe adds \r\n on Windows even after stripping \r, breaking bash
# keyword parsing ('then\r' != 'then'). Using a Windows temp file path has its own
# wslpath/spaces issues. Solution: base64-encode the script in PowerShell and pass
# the encoded string as a single argument; bash decodes and pipes to bash -s
# entirely within Linux -- no PowerShell pipe, no path conversion, no CRLF.
# Extra positional args after $Script are forwarded to the script as $1, $2, ...
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
# Step 1: .wslconfig -- mirrored networking
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
    Write-Host '.wslconfig already correct -- no shutdown needed'
  }
} else {
  Set-Content $wslcfgPath $wslcfgWant -Encoding UTF8
  $needsShutdown = $true
  Write-Host 'Created .wslconfig'
}

if ($needsShutdown) {
  Write-Host 'Running wsl --shutdown to apply new .wslconfig...'
  & wsl.exe --shutdown
  Start-Sleep -Seconds 3
  Write-Host 'Shutdown complete'
}

# -----------------------------------------------------------------------
# Step 2: Windows Firewall -- allow distro's sshd port inbound
# -----------------------------------------------------------------------
$fwRuleName = "WSL2 SSH $Port Inbound"
Step "Firewall rule: $fwRuleName"
$rule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
if ($rule) {
  Write-Host 'Rule already exists'
} else {
  New-NetFirewallRule `
    -DisplayName $fwRuleName `
    -Direction   Inbound `
    -Protocol    TCP `
    -LocalPort   $Port `
    -Action      Allow | Out-Null
  Write-Host "Firewall rule created: $fwRuleName"
}

# -----------------------------------------------------------------------
# Step 2b: Set sshd port inside the distro and restart sshd.
# Uses Invoke-WslBash (single-quoted here-string) -- the double-quoted @"..."@
# form passes \r\n line endings to bash via wsl.exe, breaking keyword parsing.
# -----------------------------------------------------------------------
Step "Configure sshd port $Port in distro '$Name'"
$sshdScript = @'
apt-get install -y --no-install-recommends openssh-server 2>&1 | tail -3
mkdir -p /etc/ssh/sshd_config.d
printf 'Port %s\n' "$1" > /etc/ssh/sshd_config.d/wsl2-port.conf
service ssh restart || service sshd restart || true
'@
Invoke-WslBash $Name root $sshdScript "$Port"
Write-Host "sshd configured on port $Port"

# -----------------------------------------------------------------------
# Step 3: Ensure SSH key exists, then read WSL2 public key.
# Uses Invoke-WslBash -- PowerShell's pipe adds \r\n on Windows,
# breaking bash keyword parsing.
# -----------------------------------------------------------------------
Step "Ensure SSH key exists in distro '$Name'"
$keyScript = @'
set -euo pipefail
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "${USER}@wsl2" -N ""
  chmod 600 ~/.ssh/id_ed25519
  chmod 644 ~/.ssh/id_ed25519.pub
  echo "SSH key generated"
else
  echo "SSH key already exists"
fi
'@
Invoke-WslBash $Name $User $keyScript
$wsl2PubKey = (& wsl.exe -d $Name -u $User -- cat "/home/$User/.ssh/id_ed25519.pub" 2>$null)
if (-not $wsl2PubKey) {
  throw "Could not read WSL2 public key from distro '$Name' as user '$User'"
}
$wsl2PubKey = $wsl2PubKey.Trim()
Write-Host "WSL2 public key: $wsl2PubKey"

# -----------------------------------------------------------------------
# Step 4: In-distro SSH mesh bootstrap.
# All Linux work (avahi wait, CIFS mount, ~/.ssh symlinks, pubkey injection,
# host block) is handled by setup-shared-ssh.sh running inside the distro.
# PowerShell only delivers secrets/keys and calls the script.
# -----------------------------------------------------------------------
if (-not $SmbPassword) {
  Warn 'SmbPassword not provided -- skipping shared SSH setup'
  Warn 'Run with -SmbPassword to wire the distro into the SSH mesh'
} else {

  Step "Write .smbcredentials in distro '$Name'"
  # Pipe via stdin to avoid password appearing in process args.
  "username=$User`npassword=$SmbPassword" | & wsl.exe -d $Name -u $User -- `
    bash -c 'cat > ~/.smbcredentials && chmod 600 ~/.smbcredentials'
  Write-Host '.smbcredentials written'

  # Deliver runner pubkeys to /tmp/ inside the distro so setup-shared-ssh.sh
  # can inject them into the shared authorized_keys.
  foreach ($pair in @(
    @{ File = "$env:USERPROFILE\dgx-key.pub"; Dest = '/tmp/dgx-key.pub' },
    @{ File = "$env:USERPROFILE\agx-key.pub"; Dest = '/tmp/agx-key.pub' }
  )) {
    if (Test-Path $pair.File) {
      $pubKey = (Get-Content $pair.File -Raw).Trim()
      $writeScript = 'printf ''%s\n'' "$1" > ' + $pair.Dest
      Invoke-WslBash $Name root $writeScript $pubKey
      Write-Host "Written $($pair.Dest) in distro"
    } else {
      Warn "Key file not found: $($pair.File) -- skipping"
    }
  }

  # Run setup-shared-ssh.sh inside the distro.
  # The script was SCP'd to %USERPROFILE% by the GHA workflow alongside this script.
  $setupScript = "$env:USERPROFILE\setup-shared-ssh.sh"
  if (-not (Test-Path $setupScript)) {
    throw "setup-shared-ssh.sh not found at $setupScript -- was it SCP'd by the workflow?"
  }
  $setupSh = Get-Content $setupScript -Raw
  Step "Run setup-shared-ssh.sh in distro '$Name'"
  Invoke-WslBash $Name root $setupSh $DgxHost $User $Name "$Port"
  Write-Host 'setup-shared-ssh.sh complete'
}

# -----------------------------------------------------------------------
# Output -- single tagged line captured by GHA
# -----------------------------------------------------------------------
Write-Host ''
Write-Host "WSL2_PUBKEY=$wsl2PubKey"
