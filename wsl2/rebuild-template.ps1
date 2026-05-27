param(
  [Parameter(Mandatory = $true)]
  [string]$SmbPassword,

  [string]$DistroUser = 'aaron',
  [string]$TarPath    = 'C:\wsl-templates\ubuntu-22.04-configured-template.tar',
  [string]$BuildName  = 'template-build',
  [string]$BuildDir   = 'C:\wsl\template-build'
)

$ErrorActionPreference = 'Stop'
function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Green }
function Die ([string]$m) { throw $m }

Step 'Preflight'
if (-not (Test-Path -LiteralPath $TarPath)) { Die "Template not found: $TarPath" }
$existing = (wsl -l -q 2>$null) | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($existing -contains $BuildName) {
  Write-Host "Unregistering leftover $BuildName..."
  wsl --unregister $BuildName 2>$null | Out-Null
}
if (Test-Path -LiteralPath $BuildDir) {
  Remove-Item -Recurse -Force $BuildDir
}

Step "Import template as '$BuildName'"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
wsl --import $BuildName $BuildDir $TarPath --version 2 | Out-Null

Step 'Patch WSL mount config + .smbcredentials'
# Build all paths in PowerShell — bash variable lookup is unreliable when
# the distro starts bare without systemd (NSS not initialised).
$UserHome  = "/home/$DistroUser"
$Creds     = "$UserHome/.smbcredentials"
$SharedDir = "$UserHome/shared"

Write-Host "==> Writing .smbcredentials at $Creds"
wsl -d $BuildName --user root -- bash -c "printf 'username=$DistroUser\npassword=$SmbPassword\n' > '$Creds' && chmod 600 '$Creds' && chown $DistroUser`:$DistroUser '$Creds' && echo done"

Write-Host "==> Creating $SharedDir"
wsl -d $BuildName --user root -- bash -c "mkdir -p '$SharedDir' && chown $DistroUser`:$DistroUser '$SharedDir' && echo done"

Write-Host "==> Removing legacy CIFS entries from /etc/fstab"
wsl -d $BuildName --user root -- bash -c "grep -v ' $SharedDir ' /etc/fstab > /tmp/fstab.new 2>/dev/null || true; cp /tmp/fstab.new /etc/fstab; rm -f /tmp/fstab.new; echo 'patched'"

Write-Host "==> Ensuring WSL pre-systemd fstab handling stays disabled"
# Do not mount the DGX shared folder from /etc/fstab on WSL2. Early mDNS/CIFS
# handling can delay boot or disrupt Plan 9/p9io, causing AcceptAsync canceled
# followed by distro powerdown. The post-boot systemd timer handles the mount.
wsl -d $BuildName --user root -- bash -c "grep -q 'mountFsTab = false' /etc/wsl.conf 2>/dev/null || printf '\n[automount]\nmountFsTab = false\n' >> /etc/wsl.conf"

Write-Host "==> /etc/fstab:"
wsl -d $BuildName --user root -- cat /etc/fstab

Step 'Remove stale id_ed25519_smb keypair'
wsl -d $BuildName --user root -- bash -c "rm -f '/home/$DistroUser/.ssh/id_ed25519_smb' '/home/$DistroUser/.ssh/id_ed25519_smb.pub' && echo done"

Step 'Shutdown distro'
wsl --terminate $BuildName

Step "Export → $TarPath"
$backup = $TarPath -replace '\.tar$', '-prev.tar'
if (Test-Path -LiteralPath $TarPath) {
  Write-Host "  Backing up old template → $backup"
  Move-Item -Force $TarPath $backup
}
wsl --export $BuildName $TarPath
Write-Host "  Exported."

Step 'Cleanup'
wsl --unregister $BuildName
Remove-Item -Recurse -Force $BuildDir -ErrorAction SilentlyContinue

Write-Host "`nDone. Template at $TarPath" -ForegroundColor Cyan
Write-Host "Old template backed up to $backup" -ForegroundColor DarkGray
