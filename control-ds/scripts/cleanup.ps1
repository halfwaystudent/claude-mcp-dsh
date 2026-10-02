# cleanup.ps1 - remove leftovers of monitoring: stray tail.exe processes that follow files in the runs folder.
# Never touches flash runs, the web server, or anything else.
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-CdsConfig
$tails = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'tail.exe' -and $_.CommandLine -match 'dsh-runs' })
foreach ($t in $tails) { Stop-Process -Id $t.ProcessId -Force -Confirm:$false -ErrorAction SilentlyContinue; Write-Output ("stopped stray tail PID " + $t.ProcessId) }
if ($tails.Count -eq 0) { Write-Output 'no stray tail processes' }
$runs = @(Get-DshRuns)
Write-Output ("live flash runs: {0}" -f $runs.Count)
$runs | ForEach-Object { Write-Output ("  PID {0} started {1}" -f $_.ProcessId, $_.CreationDate.ToString('HH:mm:ss')) }
Write-Output ("free memory: {0} GB" -f (Get-FreeGB))
