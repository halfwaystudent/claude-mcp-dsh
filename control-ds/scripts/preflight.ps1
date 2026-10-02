# preflight.ps1 - checks that must pass BEFORE any flash run. Exit code 1 on any FAIL.
param(
  [Parameter(Mandatory = $true)][string]$Workspace,
  [ValidateSet('workspace-write', 'read-only')][string]$Mode = 'workspace-write',
  [switch]$AllowConcurrent
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Get-CdsConfig
$script:fails = 0
$script:warns = 0
function Report([string]$level, [string]$name, [string]$detail) {
  if ($level -eq 'FAIL') { $script:fails++ }
  if ($level -eq 'WARN') { $script:warns++ }
  Write-Output ("{0,-4} {1}: {2}" -f $level, $name, $detail)
}

function Test-FullControl([string]$path) {
  try {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($r in (Get-Acl -LiteralPath $path).Access) {
      if ($r.AccessControlType -ne 'Allow') { continue }
      try { $sid = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) } catch { continue }
      if ($sid.Value -eq $me.Value -and (($r.FileSystemRights -band $full) -eq $full)) { return $true }
    }
  } catch {}
  return $false
}

# 1. launcher for the pinned dsh version
$launcher = Find-DshLauncher $cfg.dshVersion
$fixedDir = Join-Path $cfg.dshRuntimeRoot $cfg.dshVersion
$installHint = "npm install @deepseek-ai/dsh@" + $cfg.dshVersion + " --prefix `"" + $fixedDir + "`""
if (-not $launcher) { Report 'FAIL' 'launcher' ("dsh " + $cfg.dshVersion + " not installed. Run: " + $installHint) }
elseif ($launcher.Source -eq 'fixed') { Report 'PASS' 'launcher' ("dsh " + $launcher.Version + " at " + $launcher.Cmd) }
else { Report 'WARN' 'launcher' ("dsh " + $launcher.Version + " found only in the npx cache (" + $launcher.Cmd + "). Install the fixed copy: " + $installHint) }

# 2. workspace
if (Test-Path -LiteralPath $Workspace) {
  $ws = (Resolve-Path -LiteralPath $Workspace).Path
  if ($ws.ToLower().StartsWith($cfg.projectRoot.ToLower())) { Report 'PASS' 'workspace' $ws }
  else { Report 'WARN' 'workspace' ("$ws is outside " + $cfg.projectRoot) }
} else { Report 'FAIL' 'workspace' "$Workspace does not exist" }

# 3. memory
$free = Get-FreeGB
if ($free -ge $cfg.minFreeGB) { Report 'PASS' 'memory' ("free $free GB >= " + $cfg.minFreeGB + " GB") }
else { Report 'FAIL' 'memory' ("free $free GB < " + $cfg.minFreeGB + " GB - do not start; free memory first") }

# 4. one heavy task at a time
$runs = @(Get-DshRuns)
$py = @(Get-HeavyPython $cfg)
if (($runs.Count + $py.Count) -eq 0) { Report 'PASS' 'concurrency' 'no other flash run and no heavy python' }
elseif ($AllowConcurrent) { Report 'WARN' 'concurrency' ("{0} flash run(s), {1} heavy python (allowed by -AllowConcurrent)" -f $runs.Count, $py.Count) }
else { Report 'FAIL' 'concurrency' ("{0} flash run(s) and {1} heavy python already running - one heavy task at a time" -f $runs.Count, $py.Count) }

# 5. composed config: right model, no silently skipped bundle
if ($launcher) {
  $overlay = (Get-OverlayPath) -replace '\\', '/'
  $dump = & node $launcher.Bin --profile headless --patch $overlay --dump-config 2>&1 | Out-String
  if ($dump -match 'skipping profile bundle') { Report 'FAIL' 'config' 'a profile bundle was skipped (plugin incompatible with this dsh version) - the model would fall back to the official API' }
  else {
    $lines = $dump -split "`r?`n"
    $blocks = 0; $bad = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\s*-\s*id:\s*agent-default-model') {
        $blocks++
        $chunk = ($lines[$i..([Math]::Min($lines.Count - 1, $i + 8))]) -join "`n"
        if ($chunk -notmatch ('provider:\s*' + [regex]::Escape($cfg.expectedProvider)) -or $chunk -notmatch ('model:\s*' + [regex]::Escape($cfg.expectedModel))) { $bad++ }
      }
    }
    if ($blocks -eq 0) { Report 'FAIL' 'config' 'no agent-default-model row found in the composed config' }
    elseif ($bad -gt 0) { Report 'FAIL' 'config' ("$bad of $blocks default-model rows are not " + $cfg.expectedProvider + "/" + $cfg.expectedModel) }
    else { Report 'PASS' 'config' ("default model = " + $cfg.expectedProvider + "/" + $cfg.expectedModel + " ($blocks row(s)), no skipped bundle") }
  }
}

# 6. permission mode
Report 'PASS' 'mode' "$Mode (danger-full-access is never allowed)"

# 7. sandbox needs Full Control on the workspace for the current user
if (Test-Path -LiteralPath $Workspace) {
  if (Test-FullControl $Workspace) { Report 'PASS' 'acl' 'current user has Full Control on the workspace' }
  elseif ($Mode -eq 'workspace-write') { Report 'FAIL' 'acl' ("no explicit Full Control for the current user; the dsh 0.2 sandbox will fail. Fix: icacls <dir> /grant *<your-SID>:(OI)(CI)F  (ask the user first)") }
  else { Report 'WARN' 'acl' 'no explicit Full Control for the current user (only matters for workspace-write)' }
}

$verdict = if ($script:fails -eq 0) { 'PASS' } else { 'FAIL' }
Write-Output ("PREFLIGHT {0} ({1} fail, {2} warn)" -f $verdict, $script:fails, $script:warns)
if ($script:fails -gt 0) { exit 1 }
exit 0
