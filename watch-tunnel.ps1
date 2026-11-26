<#
  watch-tunnel.ps1 — keeps the OpenChat V2 backend + public tunnel alive.

  Runs the Flask server on http://127.0.0.1:3000 and the npm `localtunnel`
  client with a fixed subdomain, so the public URL never changes between
  restarts:

      https://openchat-v2-mrtristin.loca.lt

  Schedule it to run every minute (Task Scheduler):

      $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Users\MrTristin\Documents\openchat-v2\watch-tunnel.ps1"'
      $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                 -RepetitionInterval (New-TimeSpan -Minutes 1)
      Register-ScheduledTask -TaskName 'OpenChatV2Tunnel' -Action $action -Trigger $trigger -Force
#>

$ErrorActionPreference = 'Continue'

$ScriptDir   = $PSScriptRoot
$LocalApi    = 'http://127.0.0.1:3000'
$PublicUrl   = 'https://openchat-v2-mrtristin.loca.lt'
$Subdomain   = 'openchat-v2-mrtristin'
$LtBin       = Join-Path $ScriptDir 'node_modules\localtunnel\bin\lt.js'
$TunnelLog   = Join-Path $ScriptDir 'tools\lt.log'
$TunnelErr   = Join-Path $ScriptDir 'tools\lt.err'
$WatchLog    = Join-Path $ScriptDir 'watch-tunnel.log'

# Only one watcher at a time (the scheduled task runs every minute, but a
# restart can take longer than that).
$mutex = New-Object System.Threading.Mutex($false, 'Local\OpenChatV2Tunnel')
if (-not $mutex.WaitOne(0)) { exit 0 }

function Log($msg) {
  $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg
  Write-Output $line
  Add-Content -Path $WatchLog -Value $line
}

# ---------- 1. local Flask server ----------
function Test-LocalServer {
  try { return (Invoke-RestMethod "$LocalApi/api/health" -TimeoutSec 4).ok -eq $true } catch { return $false }
}

function Start-LocalServer {
  Log 'local server down — starting python server.py'
  Start-Process -FilePath 'python' -ArgumentList 'server.py' -WorkingDirectory $ScriptDir `
    -RedirectStandardOutput (Join-Path $ScriptDir 'server.log') `
    -RedirectStandardError  (Join-Path $ScriptDir 'server.err') -WindowStyle Hidden
  for ($i = 0; $i -lt 10; $i++) {
    Start-Sleep -Seconds 2
    if (Test-LocalServer) { return $true }
  }
  return $false
}

# ---------- 2. public tunnel ----------
function Test-PublicTunnel {
  for ($i = 0; $i -lt 3; $i++) {
    try {
      if ((Invoke-RestMethod "$PublicUrl/api/health" -TimeoutSec 12).ok -eq $true) { return $true }
    } catch { }
    if ($i -lt 2) { Start-Sleep -Seconds 3 }
  }
  return $false
}

function Get-LtProcesses {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'localtunnel' -and $_.CommandLine -match [regex]::Escape($Subdomain) }
}

function Stop-LtProcesses {
  Get-LtProcesses | ForEach-Object {
    Log "stopping stale localtunnel pid $($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
  # also stop the npx wrapper, if present
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'npx-cli\.js' -and $_.CommandLine -match [regex]::Escape($Subdomain) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Ensure-LtInstalled {
  if (Test-Path $LtBin) { return $true }
  Log 'localtunnel package missing — installing locally'
  $npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
  if (-not $npm) { Log 'npm not found'; return $false }
  & $npm install --no-save --no-package-lock localtunnel 2>&1 | Out-Null
  return (Test-Path $LtBin)
}

function Start-Tunnel {
  if (-not (Ensure-LtInstalled)) { return $false }
  Stop-LtProcesses
  Start-Sleep -Seconds 2
  Remove-Item $TunnelLog, $TunnelErr -ErrorAction SilentlyContinue

  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $node) { Log 'node not found'; return $false }

  Log "starting localtunnel for $Subdomain"
  Start-Process -FilePath $node -ArgumentList $LtBin, '--port', '3000', '--subdomain', $Subdomain `
    -WorkingDirectory $ScriptDir -RedirectStandardOutput $TunnelLog -RedirectStandardError $TunnelErr -WindowStyle Hidden

  # wait for the public URL to answer
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 3
    if (Test-PublicTunnel) { return $true }
  }
  return $false
}

# ---------- main ----------
Log 'watch-tunnel tick'

if (-not (Test-LocalServer)) {
  if (-not (Start-LocalServer)) { Log 'FATAL: local server failed to start'; exit 1 }
}

if (Test-PublicTunnel) {
  Log "tunnel OK: $PublicUrl"
  exit 0
}

Log 'public tunnel is DOWN — restarting localtunnel'
if (Start-Tunnel) {
  Log "tunnel restarted: $PublicUrl"
  exit 0
}

Log 'FATAL: tunnel failed to start'
exit 1
