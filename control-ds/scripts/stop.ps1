# stop.ps1 - interrupt ONE flash run safely. Only that run's process tree is killed; the web server and other runs are untouched.
# Refuses while a heavy child (python) is running, because killing mid-run wastes the work. Use -Force to override.
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Reason = 'stopped by orchestrator',
  [switch]$Force
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-CdsConfig
$m = Read-Manifest $cfg $Name
$p = Get-RunPaths $cfg $Name

if (-not (Test-PidAlive $m.nodePid)) { Write-Output "Run '$Name' is not running (pid $($m.nodePid) not alive). Nothing to stop."; exit 0 }

$desc = @(Get-Descendants ([int]$m.nodePid) $null)
$heavy = @($desc | Where-Object { $_.Name -eq 'python.exe' -or $_.CommandLine -match $cfg.heavyProcessPattern })
if ($heavy.Count -gt 0 -and -not $Force) {
  Write-Output 'REFUSED: a heavy child is running under this flash run (interrupting now would waste it):'
  $heavy | ForEach-Object { Write-Output ("  PID {0} {1} {2:N0} MB :: {3}" -f $_.ProcessId, $_.Name, ($_.WorkingSetSize / 1MB), $_.CommandLine.Substring(0, [Math]::Min(100, $_.CommandLine.Length))) }
  Write-Output 'Wait for it to finish (safe point), or re-run with -Force.'
  exit 3
}

& taskkill /PID $m.nodePid /T /F | Out-Null
Start-Sleep -Seconds 2
$still = Test-PidAlive $m.nodePid
$orph = @(Get-HeavyPython $cfg | Where-Object { $desc.ProcessId -contains $_.ProcessId })
$rec = [ordered]@{ name = $Name; stoppedAt = (Get-Date).ToString('s'); reason = $Reason; forced = [bool]$Force; heavyChildrenKilled = $heavy.Count; sessionId = $m.sessionId }
($rec | ConvertTo-Json) | Set-Content -Encoding UTF8 $p.Stopped

if ($still) { Write-Output "ERROR: node pid $($m.nodePid) is still alive."; exit 1 }
Write-Output ("STOPPED run '{0}' (killed {1} process(es) in its tree). Orphan heavy python left: {2}" -f $Name, ($desc.Count + 1), $orph.Count)
Write-Output ("Work on disk is preserved. To continue: write a resume sheet and dispatch with -Continue $Name (or -AllowNewSession).")
Write-Output ("free memory: {0} GB   other live flash runs: {1}" -f (Get-FreeGB), @(Get-DshRuns).Count)
exit 0
