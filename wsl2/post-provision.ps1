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
& wsl.exe -d $Name -u root -- bash -c "printf 'Port %d\n' $Port > /etc/ssh/sshd_config.d/wsl2-port.conf && systemctl restart ssh"
Write-Host "sshd configured on port $Port"

# -----------------------------------------------------------------------
# Step 3: Start distro and read WSL2 public key
# -----------------------------------------------------------------------
Step "Start distro '$Name' and read WSL2 public key"
$wsl2PubKey = (& wsl.exe -d $Name -u $User -- cat "/home/$User/.ssh/id_ed25519.pub" 2>$null)
if (-not $wsl2PubKey) {
  throw "Could not read WSL2 public key from distro '$Name' as user '$User'"
}
$wsl2PubKey = $wsl2PubKey.Trim()
Write-Host "WSL2 public key: $wsl2PubKey"

# -----------------------------------------------------------------------
# Step 3b: Add WSL2 pubkey to MSI administrators_authorized_keys
# -----------------------------------------------------------------------
Step 'Add WSL2 pubkey to administrators_authorized_keys'
$authKeysPath = 'C:\ProgramData\ssh\administrators_authorized_keys'
if (-not (Test-Path $authKeysPath)) {
  New-Item -ItemType File -Path $authKeysPath -Force | Out-Null
}
$authKeysContent = Get-Content $authKeysPath -Raw -ErrorAction SilentlyContinue
if (-not $authKeysContent) { $authKeysContent = '' }

if ($authKeysContent.Contains($wsl2PubKey)) {
  Write-Host 'WSL2 pubkey already present'
} else {
  Add-Content $authKeysPath "`n$wsl2PubKey"
  Write-Host 'WSL2 pubkey added'
}

# Fix permissions required by Windows OpenSSH
& icacls $authKeysPath /inheritance:r          | Out-Null
& icacls $authKeysPath /grant 'Administrators:F' | Out-Null
& icacls $authKeysPath /grant 'SYSTEM:F'         | Out-Null
Restart-Service sshd
Write-Host 'sshd restarted'

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

  Step "Add CIFS fstab entry (//$DgxHost/shared)"
  $fstabEntry = "//$DgxHost/shared /home/$User/shared cifs credentials=/home/$User/.smbcredentials,uid=1000,gid=1000,file_mode=0600,dir_mode=0700,_netdev 0 0"
  & wsl.exe -d $Name -u root -- bash -c `
    "grep -qF '$DgxHost/shared' /etc/fstab 2>/dev/null || printf '%s\n' '$fstabEntry' >> /etc/fstab"
  Write-Host 'fstab entry present'

  Step "Mount ~/shared in distro '$Name'"
  & wsl.exe -d $Name -u root -- bash -c "mountpoint -q /home/$User/shared || mount /home/$User/shared"
  Write-Host '~/shared mounted'

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
  $symlinkScript | & wsl.exe -d $Name -u $User -- bash -s
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
# Step 6: Add WSL2 pubkey to ~/shared/ssh/authorized_keys via Windows path.
# This makes WSL2's own key available to DGX and Orin via the shared store.
# -----------------------------------------------------------------------
Step 'Add WSL2 pubkey to shared authorized_keys (Windows path)'
$sharedAuthKeys = "$env:USERPROFILE\shared\ssh\authorized_keys"
if (Test-Path $sharedAuthKeys) {
  $sharedAuth = Get-Content $sharedAuthKeys -Raw -ErrorAction SilentlyContinue
  if (-not $sharedAuth) { $sharedAuth = '' }
  if ($sharedAuth.Contains($wsl2PubKey)) {
    Write-Host 'WSL2 pubkey already in shared authorized_keys'
  } else {
    Add-Content $sharedAuthKeys "`n$wsl2PubKey"
    Write-Host 'WSL2 pubkey added to shared authorized_keys'
  }
} else {
  Warn "Shared authorized_keys not found at $sharedAuthKeys -- run setup-shared-ssh first"
}

# -----------------------------------------------------------------------
# Step 7: Add wsl2-<Name> host block to ~/shared/ssh/config via Windows path.
# All machines (DGX, Orin, WSL2) pick this up automatically via symlinks.
# -----------------------------------------------------------------------
$hostAlias = "wsl2-$Name"
Step "Shared SSH config: $hostAlias host block"
$sharedCfgPath = "$env:USERPROFILE\shared\ssh\config"
if (Test-Path $sharedCfgPath) {
  $sharedCfg = Get-Content $sharedCfgPath -Raw -ErrorAction SilentlyContinue
  if (-not $sharedCfg) { $sharedCfg = '' }
  if ($sharedCfg -like "*Host $hostAlias*") {
    Write-Host "$hostAlias host block already present in shared config"
  } else {
    # Windows uses HostName of the Windows host (WSL2 is reachable via mirrored networking)
    # Linux machines (DGX, Orin) also use this same HostName via the shared config
    $wsl2Block = "`nHost $hostAlias`n    HostName localhost`n    User $User`n    Port $Port`n    IdentityFile ~/.ssh/id_ed25519`n    IdentitiesOnly yes"
    Add-Content $sharedCfgPath $wsl2Block
    Write-Host "$hostAlias host block added to shared config"
  }
} else {
  Warn "Shared config not found at $sharedCfgPath -- run setup-shared-ssh first"
}

# -----------------------------------------------------------------------
# Step 7b: Windows ~/.ssh/config -> hardlink to shared config (one-time).
# After this, Windows SSH picks up all host blocks from the shared store.
# -----------------------------------------------------------------------
Step 'Windows ~/.ssh/config hardlink -> shared config'
$winSshDir  = Join-Path $env:USERPROFILE '.ssh'
$winCfgPath = Join-Path $winSshDir 'config'
New-Item -ItemType Directory -Force -Path $winSshDir | Out-Null
if (Test-Path $winCfgPath) {
  Write-Host "~/.ssh/config already exists -- skipping hardlink"
  Write-Host "  To replace: del `"$winCfgPath`" && mklink /H `"$winCfgPath`" `"$sharedCfgPath`""
} elseif (Test-Path $sharedCfgPath) {
  & cmd /c "mklink /H `"$winCfgPath`" `"$sharedCfgPath`"" | Out-Null
  Write-Host "Hardlinked $winCfgPath -> $sharedCfgPath"
} else {
  Warn "Shared config not found -- Windows hardlink skipped"
}

# -----------------------------------------------------------------------
# Output -- single tagged line captured by GHA
# -----------------------------------------------------------------------
Write-Host ''
Write-Host "WSL2_PUBKEY=$wsl2PubKey"
