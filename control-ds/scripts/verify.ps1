# verify.ps1 - orchestrator-side acceptance: never trust the builder's own report.
# Runs strictly one step at a time (memory), checks free memory before each step, hashes outputs across repeated runs.
# Long job: start it with the Bash tool's run_in_background (or Start-Process) and read the log/summary afterwards.
param(
  [Parameter(Mandatory = $true)][string]$Workspace,
  [string]$TestCommand,       # e.g.  python.exe -B -m pytest -q -p no:cacheprovider
  [string]$RunCommand,        # e.g.  python.exe -B -m <package>.cli run
  [string]$OutputDir,         # directory (relative to workspace) whose files are SHA-256 hashed after each run
  [int]$Runs = 2,
  [string]$ReadonlyCommand,   # e.g.  ... -m fbbt.cli check-readonly
  [string]$SampleCommand      # e.g.  ... scripts\verify_sample.py --n 30 --seed 1
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-CdsConfig
$ws = (Resolve-Path -LiteralPath $Workspace).Path
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$rows = New-Object System.Collections.ArrayList
$aborted = $false
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONDONTWRITEBYTECODE = '1'

function Add-Row([string]$step, [string]$verdict, [string]$detail) {
  [void]$rows.Add([pscustomobject]@{ Step = $step; Verdict = $verdict; Detail = $detail })
  Write-Output ("{0,-5} {1}: {2}" -f $verdict, $step, $detail)
}

function Run-Step([string]$label, [string]$cmd) {
  $free = Get-FreeGB
  if ($free -lt $cfg.minFreeGB) { Add-Row $label 'FAIL' ("free memory $free GB < " + $cfg.minFreeGB + " GB, step not started"); $script:aborted = $true; return $null }
  $log = Join-Path $cfg.runsDir ("verify-$ts-$label.log")
  $t0 = Get-Date
  $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $cmd + '"') -WorkingDirectory $ws -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') -WindowStyle Hidden -Wait -PassThru
  $secs = [int]((Get-Date) - $t0).TotalSeconds
  return [pscustomobject]@{ Exit = $proc.ExitCode; Secs = $secs; Log = $log }
}

function Get-DirHashes([string]$dir) {
  $h = @{}
  foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($dir.Length).TrimStart('\')
    $h[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
  }
  return $h
}

# 1. tests
if ($TestCommand -and -not $aborted) {
  $r = Run-Step 'tests' $TestCommand
  if ($r) {
    $txt = (Get-Content -Raw -Encoding UTF8 $r.Log -ErrorAction SilentlyContinue)
    $m = [regex]::Match([string]$txt, '(\d+) passed')
    if ($r.Exit -eq 0) { Add-Row 'tests' 'PASS' ("exit 0, {0} passed, {1}s, log {2}" -f $m.Groups[1].Value, $r.Secs, $r.Log) }
    else { Add-Row 'tests' 'FAIL' ("exit {0}, {1}s, log {2}" -f $r.Exit, $r.Secs, $r.Log) }
  }
}

# 2. repeated runs + output hashes
if ($RunCommand -and $OutputDir -and -not $aborted) {
  $outAbs = Join-Path $ws $OutputDir
  $sets = @()
  for ($i = 1; $i -le $Runs -and -not $aborted; $i++) {
    $r = Run-Step ("run$i") $RunCommand
    if (-not $r) { break }
    if ($r.Exit -ne 0) { Add-Row ("run$i") 'FAIL' ("exit {0}, {1}s, log {2}" -f $r.Exit, $r.Secs, $r.Log); $aborted = $true; break }
    $sets += , (Get-DirHashes $outAbs)
    Add-Row ("run$i") 'PASS' ("exit 0, {0}s, {1} output files hashed" -f $r.Secs, $sets[$sets.Count - 1].Count)
  }
  if ($sets.Count -ge 2) {
    $diff = @()
    $first = $sets[0]
    for ($k = 1; $k -lt $sets.Count; $k++) {
      foreach ($key in ($first.Keys + $sets[$k].Keys | Sort-Object -Unique)) {
        if ($first[$key] -ne $sets[$k][$key]) { $diff += $key }
      }
    }
    $diff = $diff | Sort-Object -Unique
    if ($diff.Count -eq 0) { Add-Row 'determinism' 'PASS' ("{0} runs give byte-identical outputs ({1} files)" -f $sets.Count, $first.Count) }
    else { Add-Row 'determinism' 'FAIL' ("differing files: " + ($diff -join ', ')) }
  }
}

# 3. sample check and read-only check
foreach ($pair in @(@('sample', $SampleCommand), @('readonly', $ReadonlyCommand))) {
  if ($pair[1] -and -not $aborted) {
    $r = Run-Step $pair[0] $pair[1]
    if ($r) {
      $tail = ((Get-Content -Encoding UTF8 $r.Log -Tail 2 -ErrorAction SilentlyContinue) -join ' | ')
      if ($r.Exit -eq 0) { Add-Row $pair[0] 'PASS' ("exit 0, {0}s :: {1}" -f $r.Secs, $tail) }
      else { Add-Row $pair[0] 'FAIL' ("exit {0}, {1}s :: {2}" -f $r.Exit, $r.Secs, $tail) }
    }
  }
}

# 4. no bytecode caches leaked into any sibling source worktree
$leaks = @()
foreach ($d in (Get-ChildItem (Split-Path -Parent $ws) -Directory -ErrorAction SilentlyContinue)) {
  if ($d.FullName -eq $ws) { continue }
  foreach ($sub in 'data', 'docs') {
    $q = Join-Path $d.FullName $sub
    if (Test-Path $q) { $leaks += @(Get-ChildItem -LiteralPath $q -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue) }
  }
}
if ($leaks.Count -eq 0) { Add-Row 'no-pycache-leak' 'PASS' 'no __pycache__ under sibling data/docs folders' } else { Add-Row 'no-pycache-leak' 'FAIL' (($leaks | Select-Object -First 3 | ForEach-Object { $_.FullName }) -join '; ') }

$bad = @($rows | Where-Object { $_.Verdict -eq 'FAIL' }).Count
Write-Output ("VERIFY {0} ({1} step(s), {2} failed)   logs in {3}" -f $(if ($bad -eq 0) { 'PASS' } else { 'FAIL' }), $rows.Count, $bad, $cfg.runsDir)
if ($bad -gt 0) { exit 1 }
exit 0
