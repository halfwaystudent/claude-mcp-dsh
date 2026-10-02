# dispatch.ps1 - start a flash (dsh headless, Command Code DeepSeek V4.1 Flash) run, detached, with a JSON event log.
# The task text is read from a UTF-8 file on STDIN (multi-line positional args get truncated by the .cmd shim).
param(
  [Parameter(Mandatory = $true)][string]$Workspace,
  [Parameter(Mandatory = $true)][string]$TaskFile,
  [Parameter(Mandatory = $true)][string]$Name,
  [ValidateSet('workspace-write', 'read-only')][string]$Mode,
  [string]$Continue,          # previous run name: continue its session while its context is small enough
  [string]$SessionId,         # explicit session id to continue
  [switch]$AllowNewSession,   # with -Continue: if context is too large, start a fresh session instead of refusing
  [switch]$SkipPreflight,
  [switch]$AllowConcurrent
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-CdsConfig
if (-not $Mode) { $Mode = $cfg.defaultMode }

if ($Name -notmatch '^[A-Za-z0-9._-]+$') { Write-Output "ERROR: -Name may only contain letters, digits, '.', '_' and '-'"; exit 2 }
if (-not (Test-Path -LiteralPath $TaskFile)) { Write-Output "ERROR: task file not found: $TaskFile"; exit 2 }
if ((Get-Item -LiteralPath $TaskFile).Length -eq 0) { Write-Output "ERROR: task file is empty"; exit 2 }
if (-not (Test-Path -LiteralPath $Workspace)) { Write-Output "ERROR: workspace not found: $Workspace"; exit 2 }
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
$TaskFile = (Resolve-Path -LiteralPath $TaskFile).Path
$paths = Get-RunPaths $cfg $Name
if (Test-Path $paths.Manifest) { Write-Output "ERROR: a run named '$Name' already exists. Pick a new name (e.g. $Name-2)."; exit 2 }

# preflight
if (-not $SkipPreflight) {
  $pfArgs = @{ Workspace = $Workspace; Mode = $Mode }
  if ($AllowConcurrent) { $pfArgs.AllowConcurrent = $true }
  $pfOut = & (Join-Path $PSScriptRoot 'preflight.ps1') @pfArgs
  $pfOut | ForEach-Object { Write-Output $_ }
  if ($LASTEXITCODE -ne 0) { Write-Output 'ABORT: preflight failed, nothing was started.'; exit 1 }
}

# session decision
$sessionToUse = $null
$decision = 'NEW session'
if ($SessionId) { $sessionToUse = $SessionId; $decision = "CONTINUE explicit session $SessionId" }
elseif ($Continue) {
  $prev = Read-Manifest $cfg $Continue
  if ($prev.workspace -ne $Workspace) { Write-Output ("ERROR: run '$Continue' used workspace " + $prev.workspace + "; a session can only continue in the same workspace."); exit 2 }
  if (Test-PidAlive $prev.nodePid) { Write-Output "ERROR: run '$Continue' is still running (its session is locked). Wait for it or stop it first."; exit 2 }
  $pev = Read-Events (Get-RunPaths $cfg $Continue).Jsonl
  $prevSid = Get-FirstSessionId $pev
  if ($prev.sessionIdRequested) { $prevSid = $prev.sessionIdRequested }   # a continued run keeps its original session
  if (-not $prevSid) { Write-Output "ERROR: could not find the session id of run '$Continue'."; exit 2 }
  $ctx = Get-ContextTokens $pev
  if ($ctx -lt $cfg.continueBelowTokens) { $sessionToUse = $prevSid; $decision = "CONTINUE session $prevSid (context $ctx tokens < " + $cfg.continueBelowTokens + ")" }
  elseif ($AllowNewSession) { $decision = "NEW session (previous context $ctx tokens >= " + $cfg.continueBelowTokens + "; the task file must be a self-contained resume/handoff sheet)" }
  else {
    Write-Output ("REFUSED: previous context is $ctx tokens (>= " + $cfg.continueBelowTokens + "; dsh auto-compacts near 800k, hard limit " + $cfg.hardLimitTokens + ").")
    Write-Output 'Re-run with -AllowNewSession and a self-contained resume sheet, or continue anyway with -SessionId <id>.'
    exit 3
  }
}

# launch
$launcher = Find-DshLauncher $cfg.dshVersion
$overlay = (Get-OverlayPath) -replace '\\', '/'
$argv = @('--profile', 'headless', '--patch', $overlay, '--json')
if ($sessionToUse) { $argv += @('--session-id', $sessionToUse) }
$argv += '-'
$env:DSH_PERMISSION_MODE = $Mode
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:PYTHONIOENCODING = 'utf-8'
if ($Mode -eq 'read-only') {
  # The read-only sandbox token cannot write %TEMP%; Windows PowerShell then falls back to ConstrainedLanguage and every
  # pwsh command fails. Point TEMP at a scratch dir that is Everyone-modify + Low-labeled (see cds-mcp.mjs ensureRoTemp).
  $roTemp = [Environment]::ExpandEnvironmentVariables($cfg.readOnlyTempDir)
  New-Item -ItemType Directory -Force $roTemp | Out-Null
  icacls $roTemp /grant '*S-1-1-0:(OI)(CI)M' | Out-Null
  icacls $roTemp /setintegritylevel '(OI)(CI)L' | Out-Null
  $env:TEMP = $roTemp; $env:TMP = $roTemp
}
$taskHash = (Get-FileHash -LiteralPath $TaskFile -Algorithm SHA256).Hash   # before launch: the running process holds the file open
$t0 = Get-Date
$shim = Start-Process -FilePath $launcher.Cmd -ArgumentList $argv -RedirectStandardInput $TaskFile -RedirectStandardOutput $paths.Jsonl -RedirectStandardError $paths.Err -WorkingDirectory $Workspace -WindowStyle Hidden -PassThru

# find the node process that belongs to this launch, and the session id
$nodePid = 0; $sid = $null
for ($i = 0; $i -lt 120; $i++) {
  Start-Sleep -Milliseconds 500
  if (-not $nodePid) {
    $kids = @(Get-Descendants ([int]$shim.Id) $null | Where-Object { $_.Name -eq 'node.exe' -and $_.CommandLine -match '--profile headless' })
    if ($kids.Count -gt 0) { $nodePid = [int]$kids[0].ProcessId }
  }
  $ev = Read-Events $paths.Jsonl
  $sid = Get-FirstSessionId $ev
  if ($nodePid -and $sid) { break }
  if (-not (Test-PidAlive $shim.Id) -and -not $nodePid) { break }
}

$man = [ordered]@{
  name = $Name; workspace = $Workspace; mode = $Mode
  taskFile = $TaskFile; taskSha256 = $taskHash
  startedAt = $t0.ToString('s'); dshVersion = $cfg.dshVersion; model = ($cfg.expectedProvider + '/' + $cfg.expectedModel)
  decision = $decision; sessionIdRequested = $sessionToUse; sessionId = $sid
  shimPid = [int]$shim.Id; nodePid = $nodePid; jsonl = $paths.Jsonl; err = $paths.Err
}
Save-Manifest $cfg $Name $man

Write-Output ("STARTED run '{0}' mode={1} workspace={2}" -f $Name, $Mode, $Workspace)
Write-Output ("  decision: $decision")
Write-Output ("  session:  $sid   node pid: $nodePid")
Write-Output ("  log:      " + $paths.Jsonl)
if (-not $sid) { Write-Output ('WARN: no session event yet. Check status.ps1 in a few seconds; stderr file: ' + $paths.Err) }
Write-Output 'NEXT: watch it with the Monitor tool:'
Write-Output ('  powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'watch.ps1') + '" -Name ' + $Name)
exit 0
