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
# Step 2b: Set sshd port inside the distro and restart sshd
# -----------------------------------------------------------------------
Step "Configure sshd port $Port in distro '$Name'"
# Install openssh-server if missing (fresh distro), write port config, restart.
# Use 'service' (works with and without systemd) and suppress non-fatal errors.
& wsl.exe -d $Name -u root -- bash -c @"
apt-get install -y --no-install-recommends openssh-server 2>&1 | tail -3
mkdir -p /etc/ssh/sshd_config.d
printf 'Port %d\n' $Port > /etc/ssh/sshd_config.d/wsl2-port.conf
service ssh restart || service sshd restart || true
"@
Write-Host "sshd configured on port $Port"

# -----------------------------------------------------------------------
# Step 3: Ensure SSH key exists, then read WSL2 public key
# Uses Invoke-WslBash (temp file) -- PowerShell's pipe adds \r\n on Windows
# even after stripping \r, breaking bash keyword parsing.
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
# Step 4: Mount ~/shared (CIFS -> DGX ~/shared) inside the distro
# Requires DGX Samba share to be running and setup-shared-ssh to have
# been run at least once to initialise ~/shared/ssh/ on DGX.
# -----------------------------------------------------------------------
if (-not $SmbPassword) {
  Warn 'SmbPassword not provided -- skipping CIFS mount and symlink setup'
  Warn 'Run with -SmbPassword to enable shared SSH config'
} else {
  Step "Write .smbcredentials in distro '$Name'"
  # Pipe via stdin to avoid password appearing in process args
  "username=$User`npassword=$SmbPassword" | & wsl.exe -d $Name -u $User -- `
    bash -c 'cat > ~/.smbcredentials && chmod 600 ~/.smbcredentials'
  Write-Host '.smbcredentials written'

  Step "Add/update CIFS fstab entry (//$DgxHost/shared)"
  $fstabEntry = "//$DgxHost/shared /home/$User/shared cifs credentials=/home/$User/.smbcredentials,uid=1000,gid=1000,file_mode=0600,dir_mode=0700,_netdev,nofail 0 0"
  # Always replace any existing entry so nofail and current options are guaranteed.
  & wsl.exe -d $Name -u root -- bash -c `
    "sed -i '\|$DgxHost/shared|d' /etc/fstab; printf '%s\n' '$fstabEntry' >> /etc/fstab"
  Write-Host 'fstab entry updated (nofail)'

  Step "Mount ~/shared in distro '$Name' (waiting for avahi/systemd to settle)"
  $mounted = $false
  for ($i = 1; $i -le 6; $i++) {
    $mc = & wsl.exe -d $Name -u root -- bash -c `
      "mountpoint -q /home/$User/shared && echo MOUNTED || (mount /home/$User/shared 2>&1 && echo MOUNTED || echo FAILED)"
    if ($mc -match 'MOUNTED') { $mounted = $true; break }
    Write-Host "  attempt $i/6 failed -- retrying in 5s..."
    Start-Sleep -Seconds 5
  }
  if ($mounted) {
    Write-Host '~/shared mounted'
  } else {
    Warn '~/shared mount failed after 6 attempts -- shared SSH config will not be updated'
  }

  Step "Create ~/.ssh symlinks -> ~/shared/ssh/"
  $symlinkScript = @'
set -euo pipefail
for f in config known_hosts authorized_keys; do
  target="$HOME/shared/ssh/$f"
  link="$HOME/.ssh/$f"
  if [[ ! -e "$target" ]]; then
    echo "WARN: $target not found -- run setup-shared-ssh first; skipping $f"
    continue
  fi
  if [[ -L "$link" ]]; then
    echo "$f already a symlink -- skipping"
  elif [[ -f "$link" ]]; then
    mv "$link" "${link}.bak"
    echo "Backed up ${link} -> ${link}.bak"
    ln -sf "$target" "$link"
    echo "Symlinked $link"
  else
    ln -sf "$target" "$link"
    echo "Symlinked $link"
  fi
done
'@
  Invoke-WslBash $Name $User $symlinkScript
  Write-Host 'SSH symlinks configured'
}

# -----------------------------------------------------------------------
# Step 5: Inject DGX and Orin pubkeys into WSL2/shared authorized_keys.
# After symlinking, ~/.ssh/authorized_keys -> ~/shared/ssh/authorized_keys
# so this write is automatically shared with all machines.
# GHA places dgx-key.pub and agx-key.pub in %USERPROFILE% via SCP.
# -----------------------------------------------------------------------
Step 'Inject runner pubkeys into shared authorized_keys'
foreach ($keyFile in @("$env:USERPROFILE\dgx-key.pub", "$env:USERPROFILE\agx-key.pub")) {
  if (-not (Test-Path $keyFile)) {
    Warn "Key file not found: $keyFile -- skipping"
    continue
  }
  $key = (Get-Content $keyFile -Raw).Trim()
  Write-Host "Injecting: $keyFile"
  $key | & wsl.exe -d $Name -u $User -- bash -c `
    'read K; grep -qF "$K" ~/.ssh/authorized_keys 2>/dev/null || printf "%s\n" "$K" >> ~/.ssh/authorized_keys'
}

# -----------------------------------------------------------------------
# Step 6: Add WSL2 pubkey to ~/shared/ssh/authorized_keys via WSL2.
# The CIFS mount lives inside WSL2 -- write via WSL2 path, not Windows path.
# -----------------------------------------------------------------------
Step 'Add WSL2 pubkey to shared authorized_keys'
$addKeyScript = @'
set -euo pipefail
target="$HOME/shared/ssh/authorized_keys"
if [[ ! -f "$target" ]]; then
  echo "WARN: $target not found -- run setup-shared-ssh first"
  exit 0
fi
KEY="$1"
if grep -qF "$KEY" "$target" 2>/dev/null; then
  echo "WSL2 pubkey already in shared authorized_keys"
else
  printf '\n%s\n' "$KEY" >> "$target"
  echo "WSL2 pubkey added to shared authorized_keys"
fi
'@
Invoke-WslBash $Name $User $addKeyScript $wsl2PubKey

# -----------------------------------------------------------------------
# Step 7: Add wsl2-<Name> host block to ~/shared/ssh/config via WSL2.
# HostName = Windows host mDNS name so DGX/Orin can reach WSL2 over LAN.
# All machines pick this up automatically via ~/.ssh symlinks -> shared store.
# -----------------------------------------------------------------------
$hostAlias = "wsl2-$Name"
$MsiHostName = ($env:COMPUTERNAME).ToLower() + ".local"
Step "Shared SSH config: $hostAlias (HostName $MsiHostName)"

$configScript = @'
set -euo pipefail
ALIAS="$1"; HOSTNAME="$2"; USER="$3"; PORT="$4"
target="$HOME/shared/ssh/config"
if [[ ! -f "$target" ]]; then
  echo "WARN: $target not found -- run setup-shared-ssh first"
  exit 0
fi
if grep -q "^Host $ALIAS" "$target" 2>/dev/null; then
  echo "$ALIAS already present in shared config"
else
  printf '\nHost %s\n    HostName %s\n    User %s\n    Port %s\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n' \
    "$ALIAS" "$HOSTNAME" "$USER" "$PORT" >> "$target"
  echo "$ALIAS added to shared config"
fi
'@
Invoke-WslBash $Name $User $configScript $hostAlias $MsiHostName $User "$Port"
Write-Host "$hostAlias host block configured"

# -----------------------------------------------------------------------
# Output -- single tagged line captured by GHA
# -----------------------------------------------------------------------
Write-Host ''
Write-Host "WSL2_PUBKEY=$wsl2PubKey"
