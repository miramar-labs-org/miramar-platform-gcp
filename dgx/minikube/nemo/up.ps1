# up.ps1

$hostSpec = "aaron@spark-79b7.local"
$pidFile  = Join-Path $env:TEMP "sparkdgx.pid"
$outLog   = Join-Path $env:TEMP "sparkdgx.out.log"
$errLog   = Join-Path $env:TEMP "sparkdgx.err.log"

$args = @(
  "-N"
  "-o"; "ExitOnForwardFailure=yes"
  "-o"; "ServerAliveInterval=30"
  "-o"; "ServerAliveCountMax=3"
  "-L"; "8001:127.0.0.1:8001"
  "-L"; "5000:127.0.0.1:5000"
  "-L"; "8888:127.0.0.1:8888"
  "-L"; "8080:192.168.49.2:80"
  "-L"; "8081:192.168.49.2:80"
  "-L"; "8082:192.168.49.2:80"
  $hostSpec
)

# Guard: ensure no null/empty args
$bad = $args | Where-Object { $_ -eq $null -or $_ -eq "" }
if ($bad) {
  Write-Host "Argument list contains null/empty values:" 
  $args | ForEach-Object { if ($_ -eq $null) { "<NULL>" } elseif ($_ -eq "") { "<EMPTY>" } else { $_ } }
  exit 1
}

$p = Start-Process -FilePath "ssh.exe" -ArgumentList $args -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput $outLog -RedirectStandardError $errLog

Set-Content -Path $pidFile -Value $p.Id -Encoding ASCII

Start-Sleep -Seconds 1

if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) {
  Write-Host "SSH exited immediately. stderr log: $errLog"
  if (Test-Path $errLog) { Get-Content $errLog -Tail 120 }
  exit 1
}

Write-Host ("SSH tunnel started. PID={0}" -f $p.Id)
Write-Host ("PID file: {0}" -f $pidFile)
Write-Host ("stdout log: {0}" -f $outLog)
Write-Host ("stderr log: {0}" -f $errLog)

Get-NetTCPConnection -State Listen -LocalPort 8001,5000,8888 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress,LocalPort,OwningProcess

$resp = Read-Host "Press Y/y to launch UI's in browser"
if ($resp -match '^[Yy]$') {
	Start-Process "http://127.0.0.1:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/#/workloads?namespace=default"
	Start-Process "http://127.0.0.1:5000"
	Start-Process "http://127.0.0.1:8888/lab"
} else {
    Write-Host "Cancelled. Not launching browser."
}