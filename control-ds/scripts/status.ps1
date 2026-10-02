# status.ps1 - where is a flash run? Use -All to list every known run (also how a new Claude window recovers state).
param([string]$Name, [switch]$All)
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-CdsConfig

function Summarize($n) {
  $m = Read-Manifest $cfg $n
  $p = Get-RunPaths $cfg $n
  $ev = Read-Events $p.Jsonl
  $alive = Test-PidAlive $m.nodePid
  $final = $ev | Where-Object { $_.type -eq 'final' } | Select-Object -Last 1
  $ctx = Get-ContextTokens $ev
  $calls = @($ev | Where-Object { $_.type -eq 'tool_call' }).Count
  [pscustomobject]@{ Name = $n; M = $m; P = $p; Ev = $ev; Alive = $alive; Final = $final; Ctx = $ctx; Calls = $calls }
}

if ($All -or -not $Name) {
  $rows = @()
  foreach ($f in (Get-ChildItem $cfg.runsDir -Filter '*.run.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)) {
    $n = $f.Name -replace '\.run\.json$', ''
    try { $s = Summarize $n } catch { continue }
    $state = if ($s.Final) { 'DONE' } elseif ($s.Alive) { 'RUNNING' } elseif (Test-Path $s.P.Stopped) { 'STOPPED' } else { 'ENDED-NO-FINAL' }
    $rows += [pscustomobject]@{ Name = $n; State = $state; Started = $s.M.startedAt; Calls = $s.Calls; CtxTokens = $s.Ctx; Mode = $s.M.mode; Workspace = $s.M.workspace }
  }
  if ($rows.Count -eq 0) { Write-Output 'No runs recorded yet.' } else { $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Output }
  Write-Output ("free memory: {0} GB   live flash runs: {1}" -f (Get-FreeGB), @(Get-DshRuns).Count)
  exit 0
}

$s = Summarize $Name
$m = $s.M
$state = if ($s.Final) { if ($s.Alive) { 'DONE (process still exiting)' } else { 'DONE' } } elseif ($s.Alive) { 'RUNNING' } elseif (Test-Path $s.P.Stopped) { 'STOPPED' } else { 'ENDED-NO-FINAL (crash or killed)' }
Write-Output ("run:        {0}   state: {1}" -f $Name, $state)
Write-Output ("workspace:  {0}   mode: {1}   model: {2}" -f $m.workspace, $m.mode, $m.model)
Write-Output ("started:    {0}   now: {1}" -f $m.startedAt, (Get-Date).ToString('s'))
Write-Output ("session:    {0}   ({1})" -f $m.sessionId, $m.decision)
$ctxNote = if ($s.Ctx -ge $cfg.hardLimitTokens) { 'ABOVE the hard limit (dsh auto-compacts near 800k) - start a new session next' } elseif ($s.Ctx -ge $cfg.continueBelowTokens) { 'above the continue limit - next run should start a new session with a resume sheet' } else { 'ok to continue this session' }
Write-Output ("context:    {0} tokens ({1})" -f $s.Ctx, $ctxNote)
Write-Output ("tool calls: {0}   events: {1}" -f $s.Calls, @($s.Ev).Count)
$real = @($s.Ev | Where-Object { $_.type -eq 'tool_result' -and $_.status -in 'error', 'failed', 'denied', 'rejected' -and (($_.result | Out-String) -notmatch 'old_string|file changed since it was read|binary file|cannot read') })
Write-Output ("real failures (routine edit/read retries excluded): {0}" -f $real.Count)
$real | Select-Object -Last 3 | ForEach-Object { $t = ($_.result | Out-String).Trim() -replace '\s+', ' '; Write-Output ("   " + $t.Substring(0, [Math]::Min(220, $t.Length))) }
Write-Output 'last 3 tool calls:'
$s.Ev | Where-Object { $_.type -eq 'tool_call' } | Select-Object -Last 3 | ForEach-Object { $i = ($_.input | ConvertTo-Json -Compress -Depth 4); Write-Output ("   " + $_.tool + " :: " + $i.Substring(0, [Math]::Min(150, $i.Length))) }
if ($s.Alive) {
  $desc = @(Get-Descendants ([int]$m.nodePid) $null | Where-Object { $_.Name -eq 'python.exe' })
  foreach ($d in $desc) { Write-Output ("heavy child: PID {0} python {1:N0} MB :: {2}" -f $d.ProcessId, ($d.WorkingSetSize / 1MB), $d.CommandLine.Substring(0, [Math]::Min(90, $d.CommandLine.Length))) }
}
Write-Output ("free memory: {0} GB" -f (Get-FreeGB))
if ($s.Final) { $t = [string]$s.Final.text; Write-Output ("FINAL (first 600 chars): " + $t.Substring(0, [Math]::Min(600, $t.Length))) }
if (-not $s.Alive -and -not $s.Final) { Write-Output ("stderr: " + ((Get-Content $s.P.Err -TotalCount 5 -ErrorAction SilentlyContinue) -join ' | ')) }
exit 0
