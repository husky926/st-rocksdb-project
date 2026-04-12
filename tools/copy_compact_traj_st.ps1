# Copy verify_traj_st_full (or similar) to a work dir, run st_meta_compact_existing,
# then optionally list SSTs for st_meta_sst_diag.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\copy_compact_traj_st.ps1
#   powershell ... -File ... -SourceDb D:\path\to\db -TargetDb D:\path\to\copy -TargetFileMb 32

param(
  [string]$SourceDb = (Join-Path $PSScriptRoot "..\data\verify_traj_st_full"),
  [string]$TargetDb = (Join-Path $PSScriptRoot "..\data\verify_traj_st_compact_work"),
  [int]$TargetFileMb = 32,
  [switch]$SkipCopy,
  [switch]$DryRunCompact
)

$ErrorActionPreference = "Stop"
$CompactExe = Join-Path $PSScriptRoot "..\rocks-demo\build\st_meta_compact_existing.exe"
if (-not (Test-Path -LiteralPath $CompactExe)) {
  Write-Error "Build first: cmake --build D:\Project\rocks-demo\build --target st_meta_compact_existing"
}

if (-not $SkipCopy) {
  if (-not (Test-Path -LiteralPath $SourceDb)) {
    Write-Error "Source DB missing: $SourceDb"
  }
  if (Test-Path -LiteralPath $TargetDb) {
    Write-Error "Target already exists: $TargetDb`nRemove it or use -SkipCopy after a manual copy."
  }
  Write-Host "robocopy mirror -> $TargetDb"
  & robocopy $SourceDb $TargetDb /E /COPY:DAT /R:1 /W:1 | Out-Host
  if ($LASTEXITCODE -ge 8) {
    Write-Error "robocopy failed (exit $LASTEXITCODE)"
  }
}

$args = @("--db", $TargetDb, "--target-file-mb", "$TargetFileMb")
if ($DryRunCompact) { $args += "--dry-run" }
Write-Host "Running: $CompactExe $($args -join ' ')"
& $CompactExe @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Optional: run diag on all SST (adjust DiagExe if needed):"
$DiagExe = Join-Path $PSScriptRoot "..\rocksdb\build\tools\st_meta_sst_diag.exe"
$ssts = Get-ChildItem -LiteralPath $TargetDb -Filter "*.sst" -File | Sort-Object Name
if ($ssts.Count -eq 0) {
  Write-Host "  (no .sst under $TargetDb)"
} else {
  Write-Host "  & `"$DiagExe`" --window 1224600000 1224800000 116.2 39.9 116.4 40.1 \"
  foreach ($f in $ssts) {
    Write-Host "      `"$($f.FullName)`" \"
  }
  Write-Host ""
  if (Test-Path -LiteralPath $DiagExe) {
    Write-Host "--- running st_meta_sst_diag (wide window) ---"
    & $DiagExe --window 1224600000 1224800000 116.2 39.9 116.4 40.1 @($ssts | ForEach-Object { $_.FullName })
  }
}
