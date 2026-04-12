#Requires -Version 5.1
<#
.SYNOPSIS
  Run preset experiments: manifest_bucket_rtree_validate + st_meta_compaction_verify.
.DESCRIPTION
  Writes console + tee to experiment_logs\run_YYYYMMDD_HHMMSS.log for Record.md.
.PARAMETER RocksDemoBuild
  Path to rocks-demo build dir (contains .exe).
.PARAMETER DataRoot
  Parent dir for verify DB paths (created if missing).
#>
param(
  [string]$RocksDemoBuild = "",
  [string]$DataRoot = ""
)

# Native exes write hints to stderr; with Stop, PowerShell 5 treats that as terminating.
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $RocksDemoBuild) {
  $RocksDemoBuild = Join-Path $ProjectRoot "rocks-demo\build"
}
if (-not $DataRoot) {
  $DataRoot = Join-Path $ProjectRoot "data\experiments"
}

$Mbrv = Join-Path $RocksDemoBuild "manifest_bucket_rtree_validate.exe"
$Verify = Join-Path $RocksDemoBuild "st_meta_compaction_verify.exe"

foreach ($exe in @($Mbrv, $Verify)) {
  if (-not (Test-Path -LiteralPath $exe)) {
    Write-Error "Missing executable: $exe`nBuild: cd rocks-demo\build && cmake -G Ninja .. && ninja manifest_bucket_rtree_validate st_meta_compaction_verify"
  }
}

New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot "experiment_logs") | Out-Null
New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$log = Join-Path $ProjectRoot "experiment_logs\run_$ts.log"

function Write-Log($msg) {
  Write-Host $msg
  Add-Content -LiteralPath $log -Value $msg
}

# Do NOT name a parameter $args — it clashes with PowerShell's automatic $args and
# breaks argument passing (all runs looked like defaults).
function Run-Cmd([string]$title, [string]$exe, [string[]]$ArgumentList) {
  Write-Log ""
  Write-Log "===== $title ====="
  Write-Log ("> " + $exe + " " + ($ArgumentList -join " "))
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $exe @ArgumentList 2>&1 | ForEach-Object {
      $line = "$_"
      Write-Host $line
      Add-Content -LiteralPath $log -Value $line
    }
  } finally {
    $ErrorActionPreference = $prevEap
  }
  if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    Write-Log "[exit $LASTEXITCODE]"
  }
}

Write-Log "Project: $ProjectRoot"
Write-Log "Log: $log"
Write-Log "RocksDemoBuild: $RocksDemoBuild"

# --- A) Synthetic Manifest index (no RocksDB) ---
Run-Cmd "A1 mbrv baseline (wide queries, medium N, read-path open_ns=100us)" $Mbrv @(
  "--files", "20000", "--queries", "5000", "--t-span", "100000", "--bucket-width", "500",
  "--open-ns", "100000"
)

Run-Cmd "A2 mbrv selective (tight time+MBR, large N, read-path open_ns=100us)" $Mbrv @(
  "--files", "200000", "--queries", "3000", "--t-span", "100000", "--bucket-width", "500",
  "--query-time-max", "40", "--query-mbr-hw-max", "0.2",
  "--open-ns", "100000"
)

Run-Cmd "A3 mbrv quick correctness" $Mbrv @(
  "--files", "2000", "--queries", "500", "--t-span", "100000", "--bucket-width", "200", "--check-only"
)

# --- B) RocksDB compaction verify (needs Release rocksdb.lib) ---
$dbOn = ($DataRoot -replace "\\", "/") + "/verify_split_on"
$dbOff = ($DataRoot -replace "\\", "/") + "/verify_split_off"

Run-Cmd "B1 compaction_verify split ON + CompactFiles + bucket=1" $Verify @(
  "--split", "--bucket-width", "1", "--db", $dbOn, "--num", "5000", "--no-st-meta"
)

Run-Cmd "B2 compaction_verify split OFF baseline" $Verify @(
  "--db", $dbOff, "--num", "5000", "--no-st-meta"
)

Write-Log ""
Write-Log "Done. Paste key lines into Project\Record.md (purpose / result / expectation / reason / next)."
