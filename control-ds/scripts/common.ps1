# control-ds common helpers.
# ASCII ONLY in every .ps1 of this skill: Windows PowerShell 5.1 reads BOM-less files as ANSI (GBK here),
# and non-ASCII text can swallow quotes and break the script. Put Chinese text in separate UTF-8 .txt/.md files.
$ErrorActionPreference = 'Continue'
$script:SkillRoot = Split-Path -Parent $PSScriptRoot

function Get-CdsConfig {
  $p = Join-Path $script:SkillRoot 'config.json'
  $c = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
  $c.runsDir = [Environment]::ExpandEnvironmentVariables($c.runsDir)
  if ($c.dshRuntimeRoot) { $c.dshRuntimeRoot = [Environment]::ExpandEnvironmentVariables($c.dshRuntimeRoot) }
  if (-not (Test-Path $c.runsDir)) { New-Item -ItemType Directory -Force $c.runsDir | Out-Null }
  return $c
}

function Get-OverlayPath { (Join-Path $script:SkillRoot 'assets\cc-flash-overlay.yml') }

# Fixed install first: <dshRuntimeRoot>\<version> (npm install @deepseek-ai/dsh@<version> --prefix <dir>).
# The npx cache is only a fallback (Source = 'npx-cache'): it disappears when the npm cache is cleaned.
function Find-DshLauncher([string]$version) {
  $cfg = Get-CdsConfig
  $dirs = @()
  if ($cfg.dshRuntimeRoot) { $dirs += [pscustomobject]@{ Dir = (Join-Path $cfg.dshRuntimeRoot $version); Source = 'fixed' } }
  $root = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
  foreach ($d in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) { $dirs += [pscustomobject]@{ Dir = $d.FullName; Source = 'npx-cache' } }
  foreach ($d in $dirs) {
    $pj = Join-Path $d.Dir 'node_modules\@deepseek-ai\dsh\package.json'
    if (-not (Test-Path $pj)) { continue }
    $v = (Get-Content -Raw -Encoding UTF8 $pj | ConvertFrom-Json).version
    if ($v -eq $version) {
      return [pscustomobject]@{
        Cmd = (Join-Path $d.Dir 'node_modules\.bin\dsh.cmd')
        Bin = (Join-Path $d.Dir 'node_modules\@deepseek-ai\dsh\lib\bin.js')
        Version = $v
        Source = $d.Source
      }
    }
  }
  return $null
}

function Get-FreeGB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1) }

# Tolerant reader: shares the file with the writer, ignores a half-written last line.
function Read-Events([string]$path) {
  if (-not (Test-Path $path)) { return @() }
  $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd()
  } finally { $fs.Dispose() }
  $out = New-Object System.Collections.ArrayList
  foreach ($l in ($txt -split "`n")) {
    if ($l.Trim()) { try { [void]$out.Add(($l | ConvertFrom-Json)) } catch {} }
  }
  return ,$out.ToArray()
}

# Context size at the last step = uncached input + cache read + cache write.
function Get-ContextTokens($events) {
  $u = $events | Where-Object { $_.type -eq 'status' -and $_.phase -eq 'step_end' -and $_.usage } | Select-Object -Last 1
  if (-not $u) { return 0 }
  return [int]($u.usage.inputTokens + $u.usage.cacheReadTokens + $u.usage.cacheWriteTokens)
}

function Get-RunPaths($cfg, [string]$name) {
  [pscustomobject]@{
    Jsonl    = (Join-Path $cfg.runsDir "$name.jsonl")
    Err      = (Join-Path $cfg.runsDir "$name.err")
    Manifest = (Join-Path $cfg.runsDir "$name.run.json")
    Stopped  = (Join-Path $cfg.runsDir "$name.stopped.json")
  }
}

function Read-Manifest($cfg, [string]$name) {
  $p = (Get-RunPaths $cfg $name).Manifest
  if (-not (Test-Path $p)) { throw "No run named '$name' ($p not found)" }
  Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
}

function Save-Manifest($cfg, [string]$name, $obj) {
  $p = (Get-RunPaths $cfg $name).Manifest
  ($obj | ConvertTo-Json -Depth 6) | Set-Content -Encoding UTF8 $p
}

# Live headless dsh node processes (all runs).
function Get-DshRuns {
  Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'node.exe' -and $_.CommandLine -match '--profile headless' }
}

function Get-Descendants([int]$rootPid, $all) {
  if (-not $all) { $all = Get-CimInstance Win32_Process }
  $res = @()
  foreach ($c in ($all | Where-Object { $_.ParentProcessId -eq $rootPid })) {
    $res += $c
    $res += Get-Descendants ([int]$c.ProcessId) $all
  }
  return $res
}

function Test-PidAlive($p) { if (-not $p) { return $false }; return [bool](Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue) }

function Get-HeavyPython($cfg) {
  Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'python.exe' -and $_.CommandLine -match $cfg.heavyProcessPattern }
}

function Get-FirstSessionId($events) {
  $s = $events | Where-Object { $_.type -eq 'session' } | Select-Object -First 1
  if ($s) { return [string]$s.sessionId }
  return $null
}
