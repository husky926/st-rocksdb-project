# Sum "# entries" from sst_dump --show_properties for each *.sst under a DB dir.
# Uses Process API so stderr (e.g. "Corruption: bad block contents") does not
# trigger PowerShell ErrorAction / NativeCommandError when $ErrorActionPreference = Stop.
param(
  [string]$DbPath = "D:\Project\data\verify_traj_st_full",
  [string]$SstDump = "D:\Project\rocksdb\build\tools\sst_dump.exe"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $SstDump)) {
  Write-Error "Missing sst_dump: $SstDump`nBuild: cmake --build D:\Project\rocksdb\build --config Release --target sst_dump"
}
$ssts = Get-ChildItem -LiteralPath $DbPath -Filter "*.sst" -File | Sort-Object Name
if ($ssts.Count -eq 0) {
  Write-Error "No .sst under $DbPath"
}

function Invoke-SstDumpProperties {
  param([string]$Exe, [string]$SstFile)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = "--file=`"$SstFile`" --show_properties"
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return [PSCustomObject]@{
    ExitCode = $p.ExitCode
    Text     = $stdout + $stderr
  }
}

$total = 0
foreach ($f in $ssts) {
  $r = Invoke-SstDumpProperties -Exe $SstDump -SstFile $f.FullName
  if ($r.Text -match "Corruption:") {
    Write-Host "$($f.Name): (stderr mentions Corruption; still parsing properties if present) exit=$($r.ExitCode)"
  }
  $m = [regex]::Match($r.Text, "# entries:\s*(\d+)")
  if (-not $m.Success) {
    Write-Host "$($f.Name): (no # entries line) exit=$($r.ExitCode)"
    continue
  }
  $n = [int64]$m.Groups[1].Value
  $total += $n
  Write-Host "$($f.Name) entries=$n exit=$($r.ExitCode)"
}
Write-Host "---"
Write-Host "sst_files=$($ssts.Count) sum_entries_from_sst_dump=$total"
