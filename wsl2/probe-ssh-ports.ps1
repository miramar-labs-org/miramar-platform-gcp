param(
  [int]$StartPort = 2222,
  [int]$EndPort = 2299,
  [string]$Distro = 'dev',
  [int]$TimeoutSeconds = 2
)

$ErrorActionPreference = 'Stop'

function Die([string]$Message) {
  Write-Error $Message
  exit 1
}

function Get-ExcludedTcpPorts([string]$AddressFamily) {
  $output = & netsh interface $AddressFamily show excludedportrange protocol=tcp
  foreach ($line in $output) {
    if ($line -match '^\s*(\d+)\s+(\d+)') {
      [pscustomobject]@{
        Start = [int]$Matches[1]
        End   = [int]$Matches[2]
      }
    }
  }
}

function Test-WindowsPort([int]$Port, [object[]]$ExcludedRanges) {
  $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($listener) {
    return "windows-listener"
  }

  $excluded = $ExcludedRanges | Where-Object { $_.Start -le $Port -and $Port -le $_.End } | Select-Object -First 1
  if ($excluded) {
    return "windows-excluded:$($excluded.Start)-$($excluded.End)"
  }

  return $null
}

function Test-WslSshdBind([string]$DistroName, [int]$Port, [int]$Timeout) {
  $pidFile = "/run/sshd-port-probe-$Port.pid"
  $bash = @"
install -d -m 0755 /run/sshd
timeout ${Timeout}s /usr/sbin/sshd -D -e -f /dev/null \
  -o HostKey=/etc/ssh/ssh_host_ed25519_key \
  -o HostKey=/etc/ssh/ssh_host_rsa_key \
  -o Port=$Port \
  -o PidFile=$pidFile
"@

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & wsl.exe -d $DistroName --user root --exec /bin/bash -lc $bash 2>&1
    $rc = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  if ($rc -eq 124) {
    return [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = ($output -join ' ') }
  }

  $detail = ($output -join ' ').Trim()
  if (-not $detail) {
    $detail = "wsl sshd bind probe exited $rc"
  }
  return [pscustomobject]@{ Ok = $false; Reason = 'wsl-bind-failed'; Detail = $detail }
}

function Format-Ranges([int[]]$Ports) {
  if (-not $Ports -or $Ports.Count -eq 0) {
    return @()
  }

  $sorted = $Ports | Sort-Object -Unique
  $ranges = New-Object System.Collections.Generic.List[string]
  $start = $sorted[0]
  $prev = $sorted[0]

  if ($sorted.Count -eq 1) {
    return @("$start")
  }

  foreach ($port in $sorted[1..($sorted.Count - 1)]) {
    if ($port -eq ($prev + 1)) {
      $prev = $port
      continue
    }

    if ($start -eq $prev) {
      $ranges.Add("$start")
    } else {
      $ranges.Add("$start-$prev")
    }
    $start = $port
    $prev = $port
  }

  if ($start -eq $prev) {
    $ranges.Add("$start")
  } else {
    $ranges.Add("$start-$prev")
  }

  return $ranges
}

if ($StartPort -lt 1 -or $EndPort -gt 65535 -or $StartPort -gt $EndPort) {
  Die "Invalid port range: $StartPort-$EndPort"
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Die 'wsl.exe not found.'
}

$distros = & wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim("`0").Trim() } | Where-Object { $_ }
if ($distros -notcontains $Distro) {
  Die "Distro '$Distro' is not registered. Available distros: $($distros -join ', ')"
}

Write-Host "Probing SSH ports $StartPort-$EndPort with WSL distro '$Distro'..."
Write-Host "This starts the distro temporarily and runs sshd under timeout for each candidate port."

$excluded = @()
$excluded += Get-ExcludedTcpPorts -AddressFamily ipv4
$excluded += Get-ExcludedTcpPorts -AddressFamily ipv6

$results = New-Object System.Collections.Generic.List[object]
for ($port = $StartPort; $port -le $EndPort; $port++) {
  $blocked = Test-WindowsPort -Port $port -ExcludedRanges $excluded
  if ($blocked) {
    $results.Add([pscustomobject]@{
      Port   = $port
      Status = 'blocked'
      Reason = $blocked
    })
    continue
  }

  $probe = Test-WslSshdBind -DistroName $Distro -Port $port -Timeout $TimeoutSeconds
  if ($probe.Ok) {
    $status = 'ok'
    $reason = 'ok'
  } else {
    $status = 'blocked'
    $reason = "$($probe.Reason): $($probe.Detail)"
  }
  $results.Add([pscustomobject]@{
    Port   = $port
    Status = $status
    Reason = $reason
  })
}

$okPorts = @($results | Where-Object { $_.Status -eq 'ok' } | ForEach-Object { [int]$_.Port })
$ranges = @(Format-Ranges -Ports $okPorts)

Write-Host ''
Write-Host 'OK ranges:'
if ($ranges.Count -eq 0) {
  Write-Host '  none'
} else {
  foreach ($range in $ranges) {
    Write-Host "  $range"
  }
}

Write-Host ''
$results | Format-Table -AutoSize
