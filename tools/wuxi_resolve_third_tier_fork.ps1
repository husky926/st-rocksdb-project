# Dot-source from Wuxi ablation / cache scripts to resolve the **third** fork DB path.
# Canonical third tier = **hourly (3600s) bucket ingest** -> `verify_wuxi_segment_bucket3600_sst`.
# Legacy folder names `776sst` / `736sst` are optional if present; SST count is always data-dependent.
#
# Usage (inside caller):
#   . (Join-Path $PSScriptRoot "wuxi_resolve_third_tier_fork.ps1")
#   $r = Get-WuxiResolvedThirdTierCsv -RocksDbPathsCsv $RocksDbPathsCsv -DataRoot $dataRoot

function Get-WuxiResolvedThirdTierCsv {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RocksDbPathsCsv,
    [Parameter(Mandatory = $true)]
    [string]$DataRoot
  )
  $dataRoot = [System.IO.Path]::GetFullPath($DataRoot)
  $forks = @(
    $RocksDbPathsCsv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
  )
  if ($forks.Count -lt 3) {
    return [PSCustomObject]@{
      RocksDbPathsCsv           = $RocksDbPathsCsv
      ResolvedThirdPath         = ""
      ThirdTierLegacyDirName    = $false
      ThirdTierUsedPathFallback = $false
    }
  }
  $thirdRequested = $forks[2]
  $candidates = @(
    (Join-Path $dataRoot "verify_wuxi_segment_bucket3600_sst"),
    (Join-Path $dataRoot "verify_wuxi_segment_776sst"),
    (Join-Path $dataRoot "verify_wuxi_segment_736sst")
  )
  if (Test-Path -LiteralPath $thirdRequested) {
    $legacy = $thirdRequested -match "verify_wuxi_segment_(776|736)sst"
    return [PSCustomObject]@{
      RocksDbPathsCsv           = $RocksDbPathsCsv
      ResolvedThirdPath         = $thirdRequested
      ThirdTierLegacyDirName    = [bool]$legacy
      ThirdTierUsedPathFallback = $false
    }
  }
  foreach ($cand in $candidates) {
    if (Test-Path -LiteralPath $cand) {
      $forks[2] = $cand
      $legacy = $cand -match "verify_wuxi_segment_(776|736)sst"
      Write-Warning (
        "Third fork DB not found at:`n  $thirdRequested`n" +
        "Using existing:`n  $cand`n" +
        "Prefer building the canonical hourly DB: verify_wuxi_segment_bucket3600_sst (tools\build_wuxi_segment_third_tier_hourly.ps1)."
      )
      return [PSCustomObject]@{
        RocksDbPathsCsv           = ($forks -join ",")
        ResolvedThirdPath         = $cand
        ThirdTierLegacyDirName    = [bool]$legacy
        ThirdTierUsedPathFallback = $true
      }
    }
  }
  throw @"
Third fork DB not found.

  Requested: $thirdRequested
  Tried candidates (in order): $($candidates -join '; ')

Build the standard hourly (3600s) bucket layout:
  powershell -NoProfile -ExecutionPolicy Bypass -File $(Join-Path $PSScriptRoot 'build_wuxi_segment_third_tier_hourly.ps1')

See docs/BUILD_AND_EXPERIMENTS.md §4.2 and EXPERIMENTS_AND_SCRIPTS.md §2.1 / §2.1a.
"@
}
