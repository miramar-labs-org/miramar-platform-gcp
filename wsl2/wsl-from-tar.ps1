param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$Name
)

$ErrorActionPreference = 'Stop'

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "WARN: $m" -ForegroundColor Yellow }
function Die ([string]$m) { throw $m }

# --- Defaults (no extra params) ---
# Match your working manual import folder style.
$RootDir   = 'C:\wsl'
$DistroDir = Join-Path $RootDir $Name

# Your template tar
$TarPath = 'C:\wsl-templates\ubuntu-24.04-configured-template.tar'

Step 'Preflight'
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Die 'wsl.exe not found.'
}

if (-not (Test-Path -LiteralPath $TarPath)) {
  Die "Template tarball not found: $TarPath"
}

New-Item -ItemType Directory -Force -Path $RootDir | Out-Null

Step "Check distro name '$Name' isn't already registered"
$distroList = & wsl.exe -l -q 2>$null
if ($distroList) {
  $names = $distroList | ForEach-Object { $_.Trim() }
  if ($names -contains $Name) {
    Die "A distro named '$Name' already exists. Remove it with: wsl --unregister $Name"
  }
}

Step "Check target folder is empty: $DistroDir"
if (Test-Path -LiteralPath $DistroDir) {
  $items = Get-ChildItem -Force -LiteralPath $DistroDir -ErrorAction SilentlyContinue
  if ($items -and $items.Count -gt 0) {
    Die "Target folder is not empty: $DistroDir`nDelete/empty it first, or choose a new name."
  }
} else {
  New-Item -ItemType Directory -Force -Path $DistroDir | Out-Null
}

Step 'Shutdown WSL (recommended before import)'
& wsl.exe --shutdown | Out-Null

Step "Import '$Name' from tarball as WSL2"
& wsl.exe --import $Name $DistroDir $TarPath --version 2 | Out-Null

Step 'Done'
Write-Host "Launch: wsl -d $Name" -ForegroundColor Cyan
