param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Name,

  [int]$IdleSeconds = 60
)

$ErrorActionPreference = 'Continue'

function Section([string]$Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Green
}

function Invoke-Step([scriptblock]$Block) {
  try {
    & $Block
  } catch {
    Write-Host "ERROR: $($_.Exception.Message)"
  }
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

function Show-WindowsWslDiagnostics {
  Section 'Windows WSL version and status'
  Invoke-Step { & wsl.exe --version }
  Invoke-Step { & wsl.exe --status }

  Section 'Windows .wslconfig'
  $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
  if (Test-Path -LiteralPath $wslConfig) {
    Get-Content -LiteralPath $wslConfig
  } else {
    Write-Host "No .wslconfig found at $wslConfig"
  }

  Section 'WSL/Lxss event logs available on this host'
  $logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
    Where-Object { $_.LogName -match 'wsl|lxss|subsystem.*linux' } |
    Sort-Object LogName
  if ($logs) {
    $logs | Select-Object LogName, RecordCount, IsEnabled | Format-Table -AutoSize
  } else {
    Write-Host 'No WSL/Lxss-specific event logs found.'
  }

  if ($logs) {
    foreach ($log in $logs) {
      Section "Recent events: $($log.LogName)"
      Get-WinEvent -LogName $log.LogName -MaxEvents 50 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
        Format-List
    }
  }
}

Section 'WSL distro state before Linux diagnostics'
Show-WslList
$initialState = Get-DistroState -DistroName $Name
Write-Host "Observed initial state for '$Name': $initialState"

Show-WindowsWslDiagnostics

if ($initialState -eq 'Running') {
  Section 'Linux diagnostics while distro is still running'
  & wsl.exe -d $Name --user root --exec bash -lc @'
set +e

echo '--- /etc/wsl.conf ---'
cat /etc/wsl.conf 2>/dev/null || true
echo

echo '--- /etc/fstab ---'
cat /etc/fstab 2>/dev/null || true
echo

echo '--- systemd state ---'
systemctl is-system-running 2>&1 || true
systemctl --failed --no-pager || true
systemctl list-jobs --no-pager || true
echo

echo '--- running services ---'
systemctl list-units --type=service --state=running --no-pager || true
echo

echo '--- ssh status ---'
systemctl status ssh --no-pager || true
echo

echo '--- mount-dgx-shared status ---'
systemctl status mount-dgx-shared.timer --no-pager || true
systemctl status mount-dgx-shared.service --no-pager || true
echo

echo '--- sessions and inhibitors ---'
loginctl list-sessions --no-legend 2>/dev/null || true
systemd-inhibit --list --no-pager 2>/dev/null || true
echo

echo '--- process table ---'
ps -eo pid,ppid,stat,comm,args || true
echo

echo '--- boot journal tail before idle window ---'
journalctl -b -n 300 --no-pager || true
'@
} else {
  Section "Skipping Linux diagnostics because '$Name' is not running before idle window"
}

Section "Waiting $IdleSeconds seconds without a WSL client process"
Start-Sleep -Seconds $IdleSeconds

Section 'WSL distro state after idle window'
Show-WslList
$finalState = Get-DistroState -DistroName $Name
Write-Host "Observed final state for '$Name': $finalState"

Section 'Windows WSL diagnostics after idle window'
Show-WindowsWslDiagnostics

if ($finalState -eq 'Running') {
  Section 'Linux journal tail after idle window'
  & wsl.exe -d $Name --user root --exec bash -lc "journalctl -b -n 300 --no-pager || true"
} else {
  Section "Restarting '$Name' to collect post-stop Linux diagnostics"
  & wsl.exe -d $Name --user root --exec bash -lc @'
set +e

echo '--- boot list after restart ---'
journalctl --list-boots --no-pager || true
echo

echo '--- previous boot journal after idle stop ---'
journalctl -b -1 -n 300 --no-pager || true
echo

echo '--- current boot journal after restart ---'
journalctl -b -n 200 --no-pager || true
echo

echo '--- failed units after restart ---'
systemctl is-system-running 2>&1 || true
systemctl --failed --no-pager || true
echo

echo '--- mount and session state after restart ---'
findmnt / /mnt/c /home/aaron/shared 2>/dev/null || true
loginctl list-sessions --no-legend 2>/dev/null || true
'@

  Section "Terminating '$Name' after post-stop diagnostics"
  & wsl.exe --terminate $Name
  Show-WslList
}
