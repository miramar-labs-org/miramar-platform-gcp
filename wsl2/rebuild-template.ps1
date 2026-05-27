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

Step 'Patch fstab + .smbcredentials'
# Run as root inside the distro; single-quotes in the heredoc are fine
#  because we embed variables via PS string interpolation before passing to bash.
$patch = @"
set -euo pipefail
USER_HOME=`$(getent passwd $DistroUser | cut -d: -f6)
USER_UID=`$(id -u $DistroUser)
USER_GID=`$(id -g $DistroUser)

echo "==> Writing .smbcredentials"
printf 'username=%s\npassword=%s\n' '$DistroUser' '$SmbPassword' > "`$USER_HOME/.smbcredentials"
chmod 600 "`$USER_HOME/.smbcredentials"
chown ${DistroUser}:${DistroUser} "`$USER_HOME/.smbcredentials"

echo "==> Creating ~/shared mount point"
mkdir -p "`$USER_HOME/shared"
chown ${DistroUser}:${DistroUser} "`$USER_HOME/shared"

echo "==> Patching /etc/fstab"
if grep -qF 'spark-79b7.local/shared' /etc/fstab 2>/dev/null; then
  echo "  already present — skipping"
else
  printf '//spark-79b7.local/shared %s/shared cifs credentials=%s/.smbcredentials,uid=%s,gid=%s,vers=3.0,_netdev,nofail,file_mode=0600,dir_mode=0700 0 0\n' \
    "`$USER_HOME" "`$USER_HOME" "`$USER_UID" "`$USER_GID" >> /etc/fstab
  echo "  added"
fi

echo "==> /etc/fstab (cifs lines):"
grep cifs /etc/fstab || echo "  (none)"
"@

wsl -d $BuildName --user root -- bash -c $patch

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
