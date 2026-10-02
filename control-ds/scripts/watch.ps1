# watch.ps1 - filtered live view of a run, meant to be started with the Monitor tool.
# Prints only: first touch of each code file, real failures, context thresholds, stale warning, final/error, process exit.
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [int]$PollSec = 3,
  [int]$MaxMinutes = 29,
  [int]$StaleMinutes = 25
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-CdsConfig
$p = Get-RunPaths $cfg $Name
$m = Read-Manifest $cfg $Name
$seen = @{}
$offset = 0L
$ctxSoft = $false; $ctxHard = $false; $staleSaid = $false; $gotFinal = $false
$lastActivity = Get-Date
$deadline = (Get-Date).AddMinutes($MaxMinutes)
$routine = 'old_string|file changed since it was read|binary file|cannot read'

function Handle([string]$line) {
  try { $e = $line | ConvertFrom-Json } catch { return }
  switch ($e.type) {
    'tool_call' {
      if ($e.tool -in 'write', 'edit', 'str_replace', 'str_replace_editor') {
        $fp = [string]$e.input.file_path
        if ($fp -and ($fp -notmatch $cfg.quietFilePattern)) {
          $leaf = Split-Path -Leaf $fp
          if (-not $seen.ContainsKey($leaf)) { $seen[$leaf] = 1; Write-Output ("CHANGED " + $leaf) }
        }
      }
    }
    'tool_result' {
      if ($e.status -in 'error', 'failed', 'denied', 'rejected') {
        $t = (($e.result | Out-String).Trim() -replace '\s+', ' ')
        if ($t -notmatch $routine) { Write-Output ("FAIL " + $t.Substring(0, [Math]::Min(260, $t.Length))) }
      }
    }
    'status' {
      if ($e.phase -eq 'step_end' -and $e.usage) {
        $c = [int]($e.usage.inputTokens + $e.usage.cacheReadTokens + $e.usage.cacheWriteTokens)
        if (-not $script:ctxSoft -and $c -ge $cfg.continueBelowTokens) { $script:ctxSoft = $true; Write-Output ("CONTEXT $c tokens >= " + $cfg.continueBelowTokens + " (next run should start a new session)") }
        if (-not $script:ctxHard -and $c -ge $cfg.hardLimitTokens) { $script:ctxHard = $true; Write-Output ("CONTEXT-HARD $c tokens >= " + $cfg.hardLimitTokens + " (auto-compaction near ~800k; stop and switch session)") }
      }
      if ($e.phase -eq 'turn_end') { Write-Output ("TURN_END " + ($e.reason | ConvertTo-Json -Compress)) }
    }
    'final' { $script:gotFinal = $true; $t = [string]$e.text; Write-Output ("FINAL " + $t.Substring(0, [Math]::Min(500, $t.Length))) }
    'error' { $script:gotFinal = $true; Write-Output ("ERROR " + ($e | ConvertTo-Json -Compress -Depth 4)) }
  }
}

function Drain {
  if (-not (Test-Path $p.Jsonl)) { return }
  $fs = [System.IO.File]::Open($p.Jsonl, 'Open', 'Read', 'ReadWrite')
  try {
    if ($fs.Length -le $offset) { return }
    $fs.Position = $offset
    $buf = New-Object byte[] ($fs.Length - $offset)
    $n = $fs.Read($buf, 0, $buf.Length)
    # only decode complete lines; keep a partial last line for the next read
    $last = -1
    for ($i = $n - 1; $i -ge 0; $i--) { if ($buf[$i] -eq 10) { $last = $i; break } }
    if ($last -lt 0) { return }
    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $last + 1)
    $script:offset += ($last + 1)
    $script:lastActivity = Get-Date
    $script:staleSaid = $false
    foreach ($l in ($text -split "`n")) { if ($l.Trim()) { Handle $l } }
  } finally { $fs.Dispose() }
}

Write-Output ("WATCHING run '" + $Name + "' (pid " + $m.nodePid + ", session " + $m.sessionId + ")")
while ($true) {
  Drain
  if ($gotFinal) { Drain; Write-Output 'RUN-COMPLETE'; exit 0 }
  if ($m.nodePid -and -not (Test-PidAlive $m.nodePid)) {
    Start-Sleep -Seconds 1; Drain
    if ($gotFinal) { Write-Output 'RUN-COMPLETE'; exit 0 }
    Write-Output 'PROCESS-EXITED without a final event (crash, kill, or memory reaper). Check status.ps1 and the .err file.'
    exit 4
  }
  if (-not $staleSaid -and ((Get-Date) - $lastActivity).TotalMinutes -ge $StaleMinutes) {
    $staleSaid = $true
    Write-Output ("STALE no new events for $StaleMinutes minutes (it may be waiting on a long job; check status.ps1)")
  }
  if ((Get-Date) -gt $deadline) { Write-Output 'WATCH-TIMEOUT run still going; re-arm the monitor'; exit 0 }
  Start-Sleep -Seconds $PollSec
}
