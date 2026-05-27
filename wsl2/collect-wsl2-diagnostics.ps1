param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Name,

  [int]$IdleSeconds = 45
)

$ErrorActionPreference = 'Continue'

function Section([string]$Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Green
}

function Show-WslList {
  & wsl.exe -l -v
}

function Get-DistroState([string]$DistroName) {
  $lines = & wsl.exe -l -v 2>$null
  foreach ($line in $lines) {
    $clean = ($line -replace "`0", '').Trim()
    if ($clean -match "^\*?\s*$([regex]::Escape($DistroName))\s+(\S+)") {
      return $Matches[1]
    }
  }
  return 'unknown'
}

Section "WSL distro state before idle window"
Show-WslList

Section "Waiting $IdleSeconds seconds without a WSL client process"
Start-Sleep -Seconds $IdleSeconds

Section "WSL distro state after idle window"
Show-WslList
$state = Get-DistroState -DistroName $Name
Write-Host "Observed state for '$Name': $state"

Section 'Recent Windows Lxss events'
try {
  Get-WinEvent -LogName 'Microsoft-Windows-Lxss/Operational' -MaxEvents 80 |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List
} catch {
  Write-Host "Could not read Microsoft-Windows-Lxss/Operational: $($_.Exception.Message)"
}

if ($state -ne 'Running') {
  Section "Skipping Linux diagnostics because '$Name' is not running"
  exit 0
}

Section 'Linux WSL and service diagnostics'
& wsl.exe -d $Name --user root --exec bash -lc @'
set +e
echo '--- /etc/wsl.conf ---'
cat /etc/wsl.conf 2>/dev/null || true
echo
echo '--- /etc/fstab ---'
cat /etc/fstab 2>/dev/null || true
echo
echo '--- system state ---'
systemctl is-system-running 2>&1 || true
systemctl --failed --no-pager || true
echo
echo '--- ssh status ---'
systemctl status ssh --no-pager || true
echo
echo '--- mount-dgx-shared timer/service ---'
systemctl status mount-dgx-shared.timer --no-pager || true
systemctl status mount-dgx-shared.service --no-pager || true
echo
echo '--- latest journal tail ---'
journalctl -b -n 160 --no-pager || true
'@
