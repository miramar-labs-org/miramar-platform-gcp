# down.ps1 (kill the SSH tunnel using the PID file)
$pidFile = Join-Path $env:TEMP "sparkdgx.pid"

if (-not (Test-Path $pidFile)) {
  Write-Host "PID file not found: $pidFile"
  exit 1
}

$sshPid = (Get-Content $pidFile -ErrorAction Stop | Select-Object -First 1).Trim()
if (-not $sshPid) {
  Write-Host "PID file is empty: $pidFile"
  exit 1
}

try {
  Stop-Process -Id $sshPid -Force -ErrorAction Stop
  Write-Host "Killed process PID=$sshPid"
} catch {
  Write-Host "Failed to kill PID=$sshPid (maybe already stopped): $($_.Exception.Message)"
  exit 1
} finally {
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}
