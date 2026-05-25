param(
  [Parameter(Mandatory = $true)]
  [string]$Name,

  [string]$User = $env:USERNAME,
  [int]$Port    = 2222
)

$ErrorActionPreference = 'Stop'

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "WARN: $m" -ForegroundColor Yellow }

# Convert a Windows absolute path (C:\foo\bar) to its WSL /mnt/ equivalent
function To-WslPath([string]$winPath) {
  $drive = $winPath.Substring(0, 1).ToLower()
  $rest  = $winPath.Substring(2).Replace('\', '/')
  return "/mnt/$drive$rest"
}

# -----------------------------------------------------------------------
# Step 1: .wslconfig — mirrored networking
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
    Write-Host '.wslconfig already correct — no shutdown needed'
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
# Step 2: Windows Firewall — allow distro's sshd port inbound
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
# The template always bakes port 2222; this overrides it for non-default
# instances and makes the configured port explicit for all instances.
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
# Step 5: Inject DGX and Orin pubkeys into WSL2 authorized_keys
# GHA places dgx-key.pub and agx-key.pub in %USERPROFILE% via SCP.
# Keys are piped via stdin to avoid shell-escaping the key string.
# -----------------------------------------------------------------------
Step 'Inject runner pubkeys into WSL2 authorized_keys'
foreach ($keyFile in @("$env:USERPROFILE\dgx-key.pub", "$env:USERPROFILE\agx-key.pub")) {
  if (-not (Test-Path $keyFile)) {
    Warn "Key file not found: $keyFile — skipping"
    continue
  }
  $key = (Get-Content $keyFile -Raw).Trim()
  Write-Host "Injecting: $keyFile"
  # Pipe the key via stdin; bash reads it with 'read' to avoid arg-escaping issues
  $key | & wsl.exe -d $Name -u $User -- bash -c `
    'read K; grep -qF "$K" ~/.ssh/authorized_keys 2>/dev/null || printf "%s\n" "$K" >> ~/.ssh/authorized_keys'
}

# -----------------------------------------------------------------------
# Step 7: Windows SSH client config — add wsl2 host block
# -----------------------------------------------------------------------
$hostAlias = "wsl2-$Name"
Step "Windows SSH client config: $hostAlias host block"
$sshDir     = Join-Path $env:USERPROFILE '.ssh'
$sshCfgPath = Join-Path $sshDir 'config'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
if (-not (Test-Path $sshCfgPath)) {
  New-Item -ItemType File -Path $sshCfgPath | Out-Null
}
$existingCfg = Get-Content $sshCfgPath -Raw -ErrorAction SilentlyContinue
if (-not $existingCfg) { $existingCfg = '' }

if ($existingCfg -like "*Host $hostAlias*") {
  Write-Host "$hostAlias host block already present"
} else {
  $wsl2Block = @"

Host $hostAlias
    HostName localhost
    User $User
    Port $Port
    IdentityFile $sshDir\id_ed25519
    IdentitiesOnly yes
"@
  Add-Content $sshCfgPath $wsl2Block
  Write-Host "$hostAlias host block added (localhost:$Port)"
}

# -----------------------------------------------------------------------
# Output — single tagged line captured by GHA
# -----------------------------------------------------------------------
Write-Host ''
Write-Host "WSL2_PUBKEY=$wsl2PubKey"
