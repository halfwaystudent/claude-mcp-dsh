# web.ps1 - manage the dsh web UI server (start / status / stop). Independent of flash runs.
# Started HIDDEN (not in the taskbar) so a stray keypress or window close cannot stop it. Log + login link go to the runs folder.
param(
  [ValidateSet('start', 'status', 'stop')][string]$Action = 'status',
  [switch]$Force      # stop a server that this script did not start
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-CdsConfig
$log = Join-Path $cfg.runsDir 'dsh-web.log'
$pidFile = Join-Path $cfg.runsDir 'dsh-web.pid'
$launcherCmd = Join-Path $cfg.runsDir 'start-web.cmd'

function Get-Listener { Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Get-Url { if (Test-Path $log) { $l = Get-Content -Path $log -Encoding UTF8 | Where-Object { $_ -match 'http://127\.0\.0\.1:3080/\?token=' } | Select-Object -First 1; return $l } return $null }
function Get-Chain([int]$startPid) {
  $chain = @(); $id = $startPid
  for ($i = 0; $i -lt 4 -and $id; $i++) {
    $q = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $id) -ErrorAction SilentlyContinue
    if (-not $q) { break }
    if ($q.Name -in 'node.exe', 'cmd.exe' -and $q.CommandLine -match 'dsh') { $chain += $q; $id = $q.ParentProcessId } else { break }
  }
  return $chain
}

$ls = Get-Listener

if ($Action -eq 'status') {
  if ($ls) { Write-Output ("web server UP  pid {0}" -f $ls.OwningProcess); $u = Get-Url; if ($u) { Write-Output $u } }
  else { Write-Output 'web server DOWN' }
  exit 0
}

if ($Action -eq 'start') {
  if ($ls) { Write-Output ("already up (pid {0})" -f $ls.OwningProcess); $u = Get-Url; if ($u) { Write-Output $u }; exit 0 }
  # Register flash (ACP) sessions in the web workspace list while the server is down (it reads the list at startup).
  $sync = & node (Join-Path (Split-Path $PSScriptRoot -Parent) 'mcp\cds-mcp.mjs') --sync-web 2>$null
  Write-Output ("web workspace sync: " + $sync)
  $launcher = Find-DshLauncher $cfg.dshVersion
  if (-not $launcher) { Write-Output ("ERROR: dsh " + $cfg.dshVersion + " not installed. Run: npm install @deepseek-ai/dsh@" + $cfg.dshVersion + " --prefix `"" + (Join-Path $cfg.dshRuntimeRoot $cfg.dshVersion) + "`""); exit 1 }
  if ($launcher.Source -ne 'fixed') { Write-Output ("WARN: using dsh from the npx cache: " + $launcher.Bin) }
  $lines = @('@echo off', 'cd /d "%USERPROFILE%"', ('node "' + $launcher.Bin + '" web --no-open > "' + $log + '" 2>&1'))
  Set-Content -Path $launcherCmd -Value $lines -Encoding ASCII
  Start-Process -FilePath $launcherCmd -WindowStyle Hidden
  for ($i = 0; $i -lt 45; $i++) { Start-Sleep -Seconds 2; $ls = Get-Listener; if ($ls) { break } }
  if (-not $ls) { Write-Output 'ERROR: server did not start listening within 90 s. See the log:'; Write-Output $log; exit 1 }
  Set-Content -Path $pidFile -Value ([string]$ls.OwningProcess) -Encoding ASCII
  Write-Output ("STARTED web server pid {0} (hidden window)" -f $ls.OwningProcess)
  Write-Output (Get-Url)
  exit 0
}

if ($Action -eq 'stop') {
  if (-not $ls) { Write-Output 'web server is not running'; exit 0 }
  $mine = $false
  if (Test-Path $pidFile) { $mine = ((Get-Content $pidFile -Raw).Trim() -eq [string]$ls.OwningProcess) }
  if (-not $mine -and -not $Force) { Write-Output 'REFUSED: this server was not started by web.ps1 (the user may be running it). Ask the user, or use -Force.'; exit 3 }
  $chain = @(Get-Chain ([int]$ls.OwningProcess))
  foreach ($q in $chain) { Stop-Process -Id $q.ProcessId -Force -Confirm:$false -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
  if (Get-Listener) { Write-Output 'ERROR: still listening'; exit 1 }
  Write-Output ("STOPPED web server ({0} process(es))" -f $chain.Count)
  exit 0
}
