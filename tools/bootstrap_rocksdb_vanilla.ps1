# Clone upstream RocksDB into <Project>/rocksdb_vanilla and build rocksdb.lib (Release).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bootstrap_rocksdb_vanilla.ps1
#
# If git clone fails (proxy / no GitHub): script exits before cmake and restores README in rocksdb_vanilla.
# Without Ninja: uses vswhere + registry + PATH scan for cl.exe, or -VsInstallRoot / CMAKE_GENERATOR_INSTANCE.

param(
  [string]$ProjectRoot = "",
  # Upstream tags: see https://github.com/facebook/rocksdb/releases (v11.2.0 is not a public tag).
  [string]$Tag = "v11.0.4",
  [string]$Generator = "",
  # Optional: VS installation root (folder containing VC\, Common7\) e.g. D:\Visio — fixes "could not find VS" in plain PowerShell.
  [string]$VsInstallRoot = ""
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = Split-Path $PSScriptRoot -Parent
}
$VanillaSrc = Join-Path $ProjectRoot "rocksdb_vanilla"
$VanillaBuild = Join-Path $VanillaSrc "build"
$Marker = Join-Path $VanillaSrc "CMakeLists.txt"

function Write-VanillaReadme {
  param([string]$Dir)
  if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
  $readme = Join-Path $Dir "README_UPSTREAM.txt"
  @"
Place an UNMODIFIED upstream facebook/rocksdb tree here (e.g. tag v11.0.4; override with -Tag if needed),
then re-run: tools\bootstrap_rocksdb_vanilla.ps1

If git clone fails (proxy): fix HTTPS_PROXY / system proxy, or copy an extracted tarball into this folder.

Offline pipeline test (NOT official upstream): build rocks-demo with
  -DVANILLA_STANDIN_LINK_FORK_LIB=ON
See docs/VANILLA_ROCKSDB_BASELINE.md
"@ | Set-Content -LiteralPath $readme -Encoding utf8
}

if (Test-Path $Marker) {
  Write-Host "rocksdb_vanilla already contains CMakeLists.txt — skip clone. Building..." -ForegroundColor Yellow
} else {
  if (Test-Path $VanillaSrc) {
    $children = Get-ChildItem -Force $VanillaSrc -ErrorAction SilentlyContinue
    if ($null -ne $children -and $children.Count -gt 0) {
      Write-Host "Clearing $VanillaSrc (clone will repopulate)" -ForegroundColor DarkYellow
      Remove-Item -Recurse -Force (Join-Path $VanillaSrc "*") -ErrorAction SilentlyContinue
    }
  } else {
    New-Item -ItemType Directory -Path $VanillaSrc -Force | Out-Null
  }
  Write-Host "Cloning facebook/rocksdb tag $Tag -> $VanillaSrc" -ForegroundColor Cyan
  $repo = "https://github.com/facebook/rocksdb.git"
  # --branch accepts a tag, but shallow clone can fail on some annotated tags; fall back to fetch-by-ref.
  & git clone --depth 1 --branch $Tag $repo $VanillaSrc
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Retry: shallow fetch tag ref..." -ForegroundColor DarkYellow
    if (Test-Path $VanillaSrc) {
      Remove-Item -Recurse -Force (Join-Path $VanillaSrc "*") -ErrorAction SilentlyContinue
    } else {
      New-Item -ItemType Directory -Path $VanillaSrc -Force | Out-Null
    }
    & git -C $VanillaSrc init
    if ($LASTEXITCODE -ne 0) { Write-VanillaReadme -Dir $VanillaSrc; exit 1 }
    & git -C $VanillaSrc remote add origin $repo
    $tagRef = "refs/tags/${Tag}"
    & git -C $VanillaSrc fetch --depth 1 origin "${tagRef}:${tagRef}"
    if ($LASTEXITCODE -ne 0) {
      # Annotated tag: peel to commit (^{} must survive PowerShell — use -f, not "${Tag}^{}")
      $peel = ('refs/tags/{0}^{{}}:refs/tags/{0}' -f $Tag)
      & git -C $VanillaSrc fetch --depth 1 origin $peel
    }
    if ($LASTEXITCODE -ne 0) {
      Write-VanillaReadme -Dir $VanillaSrc
      Write-Host "Tag '$Tag' not found on origin. List tags: git ls-remote --tags $repo | Select-String ""$Tag""" -ForegroundColor Yellow
      Write-Host "Releases: https://github.com/facebook/rocksdb/releases" -ForegroundColor Yellow
      Write-Host "Fix: proxy/VPN for github.com, or unpack upstream sources into rocksdb_vanilla\." -ForegroundColor Yellow
      Write-Host "Offline bench exe: cd rocks-demo\build && cmake .. -DVANILLA_STANDIN_LINK_FORK_LIB=ON && cmake --build . --config Release --target st_segment_window_scan_vanilla" -ForegroundColor Yellow
      exit 1
    }
    & git -C $VanillaSrc checkout --detach $Tag
    if ($LASTEXITCODE -ne 0) { Write-VanillaReadme -Dir $VanillaSrc; exit 1 }
  }
}

if (-not (Test-Path $Marker)) {
  Write-VanillaReadme -Dir $VanillaSrc
  throw "Still no CMakeLists.txt under $VanillaSrc after clone step."
}

function ConvertFrom-VsWhereJsonOutput {
  param($Raw)
  if ($null -eq $Raw) {
    return $null
  }
  # vswhere may print a copyright banner before JSON unless -nologo is used; strip to first [ or {.
  $t = if ($Raw -is [string]) {
    $Raw.Trim()
  } else {
    (($Raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
  }
  if ([string]::IsNullOrWhiteSpace($t)) {
    return $null
  }
  $i = $t.IndexOf('[')
  if ($i -lt 0) {
    $i = $t.IndexOf('{')
  }
  if ($i -ge 0) {
    $t = $t.Substring($i)
  }
  try {
    return $t | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Get-VisualStudioInstallationRootFromCl {
  $full = $null
  $cmd = Get-Command cl.exe -ErrorAction SilentlyContinue
  if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
    $full = $cmd.Source
  }
  if ([string]::IsNullOrWhiteSpace($full) -and -not [string]::IsNullOrWhiteSpace($env:Path)) {
    foreach ($segment in ($env:Path -split ';')) {
      $t = $segment.Trim()
      if ($t -eq '') {
        continue
      }
      $cand = Join-Path $t 'cl.exe'
      if (Test-Path -LiteralPath $cand) {
        $full = $cand
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($full)) {
    return $null
  }
  $dir = Split-Path $full -Parent
  for ($i = 0; $i -lt 28; $i++) {
    $vcvars = Join-Path $dir "Auxiliary\Build\vcvars64.bat"
    if (Test-Path -LiteralPath $vcvars) {
      $vsRoot = Split-Path $dir -Parent
      if (Test-Path (Join-Path $vsRoot "VC\Tools\MSVC")) {
        return $vsRoot
      }
      if (Test-Path (Join-Path $vsRoot "Common7")) {
        return $vsRoot
      }
      return $vsRoot
    }
    $parent = Split-Path $dir -Parent
    if ($parent -eq $dir) {
      break
    }
    $dir = $parent
  }
  return $null
}

function Get-VisualStudioInstallationRootFromRegistry {
  foreach ($base in @(
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio',
      'HKLM:\SOFTWARE\Microsoft\VisualStudio'
    )) {
    if (-not (Test-Path -LiteralPath $base)) {
      continue
    }
    $subs = Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue |
      Where-Object { $_.PSChildName -match '^(15|16|17|18)\.' }
    foreach ($sub in $subs) {
      $setupVs = Join-Path $sub.PSPath "Setup\VS"
      $dir = $null
      if (Test-Path -LiteralPath $setupVs) {
        $dir = (Get-ItemProperty -LiteralPath $setupVs -ErrorAction SilentlyContinue).ProductDir
      }
      if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = (Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue).ShellFolder
      }
      if ([string]::IsNullOrWhiteSpace($dir)) {
        continue
      }
      $dir = $dir.TrimEnd('\')
      if (Test-Path (Join-Path $dir "VC\Tools\MSVC")) {
        return $dir
      }
    }
  }
  return $null
}

function Add-CmakeCandidatesForVsRoot {
  param(
    [string]$Root,
    [System.Collections.ArrayList]$List
  )
  if ([string]::IsNullOrWhiteSpace($Root)) {
    return
  }
  $Root = $Root.TrimEnd('\')
  if (-not (Test-Path (Join-Path $Root "VC\Tools\MSVC"))) {
    return
  }
  # Multiple generators: CMake picks the one matching the installed VS year; instance path fixes non-default drives.
  [void]$List.Add(@{ Generator = "Visual Studio 18 2026"; Instance = $Root })
  [void]$List.Add(@{ Generator = "Visual Studio 17 2022"; Instance = $Root })
  [void]$List.Add(@{ Generator = "Visual Studio 16 2019"; Instance = $Root })
}

function Get-VisualStudioCmakeCandidates {
  param([string]$PreferredVsRoot = "")
  function Return-Candidates([System.Collections.ArrayList]$list) {
    if ($null -eq $list -or $list.Count -eq 0) {
      return @()
    }
    # Do not use `return ,$list` — that wraps ArrayList in a one-element array and breaks callers.
    return @($list.ToArray())
  }
  $candidates = [System.Collections.ArrayList]@()
  if (-not [string]::IsNullOrWhiteSpace($PreferredVsRoot)) {
    Add-CmakeCandidatesForVsRoot -Root $PreferredVsRoot.TrimEnd('\') -List $candidates
  }
  # Developer PowerShell / vcvars sets this; helps when vswhere is missing or VS is non-standard.
  if (-not [string]::IsNullOrWhiteSpace($env:VSINSTALLDIR)) {
    $idir = $env:VSINSTALLDIR.TrimEnd('\')
    if (Test-Path (Join-Path $idir "VC\Tools\MSVC")) {
      [void]$candidates.Add(@{ Generator = "Visual Studio 17 2022"; Instance = $idir })
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($env:CMAKE_GENERATOR_INSTANCE)) {
    $idir = $env:CMAKE_GENERATOR_INSTANCE.TrimEnd('\')
    Add-CmakeCandidatesForVsRoot -Root $idir -List $candidates
  }
  # $env:ProgramFiles(x86) is awkward in PowerShell; use API like CMake does.
  $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
  if ([string]::IsNullOrWhiteSpace($pf86)) {
    $pf86 = "C:\Program Files (x86)"
  }
  $pf64 = $env:ProgramFiles
  if ([string]::IsNullOrWhiteSpace($pf64)) {
    $pf64 = "C:\Program Files"
  }
  $vswhere = @(
    (Join-Path $pf86 "Microsoft Visual Studio\Installer\vswhere.exe"),
    (Join-Path $pf64 "Microsoft Visual Studio\Installer\vswhere.exe")
  ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($vswhere)) {
    $vswhere = $null
  }
  if ($null -ne $vswhere) {
  function LocalJoin-VsWhereOutput($o) {
    if ($null -eq $o) {
      return ""
    }
    if ($o -is [string]) {
      return $o
    }
    return (($o | ForEach-Object { $_.ToString() }) -join "`n")
  }
  $json = & $vswhere -nologo -sort descending -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath,installationVersion -format json 2>$null
  $jsonText = (LocalJoin-VsWhereOutput $json).Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    $json = & $vswhere -nologo -sort descending -products * `
      -property installationPath,installationVersion -format json 2>$null
    $jsonText = (LocalJoin-VsWhereOutput $json).Trim()
  }
  if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
    $arr = ConvertFrom-VsWhereJsonOutput -Raw $jsonText
    if ($null -ne $arr) {
      if ($arr -isnot [System.Array]) {
        $arr = @($arr)
      }
      foreach ($inst in $arr) {
        $path = $inst.installationPath
        $ver = $inst.installationVersion
        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($ver)) {
          continue
        }
        $major = 0
        [void][int]::TryParse(($ver -split '\.')[0], [ref]$major)
        switch ($major) {
          18 {
            [void]$candidates.Add(@{ Generator = "Visual Studio 18 2026"; Instance = $path })
            [void]$candidates.Add(@{ Generator = "Visual Studio 17 2022"; Instance = $path })
          }
          17 { [void]$candidates.Add(@{ Generator = "Visual Studio 17 2022"; Instance = $path }) }
          16 { [void]$candidates.Add(@{ Generator = "Visual Studio 16 2019"; Instance = $path }) }
          15 { [void]$candidates.Add(@{ Generator = "Visual Studio 15 2017"; Instance = $path }) }
          default {
            if ($major -gt 18) {
              [void]$candidates.Add(@{ Generator = "Visual Studio 18 2026"; Instance = $path })
            }
            [void]$candidates.Add(@{ Generator = "Visual Studio 17 2022"; Instance = $path })
          }
        }
      }
    }
  }
  }

  if ($candidates.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:VCINSTALLDIR)) {
    $vcParent = Split-Path $env:VCINSTALLDIR.TrimEnd('\') -Parent
    Add-CmakeCandidatesForVsRoot -Root $vcParent -List $candidates
  }
  if ($candidates.Count -eq 0) {
    $root = Get-VisualStudioInstallationRootFromCl
    if (-not [string]::IsNullOrWhiteSpace($root)) {
      Write-Host "VS instance from cl.exe path: $root" -ForegroundColor DarkCyan
      Add-CmakeCandidatesForVsRoot -Root $root -List $candidates
    }
  }
  if ($candidates.Count -eq 0) {
    $root = Get-VisualStudioInstallationRootFromRegistry
    if (-not [string]::IsNullOrWhiteSpace($root)) {
      Write-Host "VS instance from registry: $root" -ForegroundColor DarkCyan
      Add-CmakeCandidatesForVsRoot -Root $root -List $candidates
    }
  }

  return (Return-Candidates $candidates)
}

$gen = $Generator
$vsInstance = $null
if ([string]::IsNullOrWhiteSpace($gen)) {
  $ninja = Get-Command ninja -ErrorAction SilentlyContinue
  if ($ninja) {
    $gen = "Ninja"
  } else {
    $vsList = @(Get-VisualStudioCmakeCandidates -PreferredVsRoot $VsInstallRoot)
    if ($vsList.Count -gt 0) {
      $first = $vsList[0]
      if ($first -is [hashtable]) {
        $gen = [string]$first['Generator']
        $vsInstance = [string]$first['Instance']
      } else {
        $gen = [string]$first.Generator
        $vsInstance = [string]$first.Instance
      }
    }
    if ([string]::IsNullOrWhiteSpace($gen)) {
      $gen = "Visual Studio 17 2022"
      $vsInstance = $null
      Write-Host "Ninja not in PATH — no VS candidate from vswhere/env; trying $gen -A x64 (may fail)" -ForegroundColor Yellow
    } else {
      $vsNote = if ([string]::IsNullOrWhiteSpace($vsInstance)) { '(CMake default discovery)' } else { $vsInstance }
      Write-Host "Ninja not in PATH — using $gen -A x64 (VS at $vsNote)" -ForegroundColor Yellow
    }
  }
}

if ([string]::IsNullOrWhiteSpace($gen)) {
  throw "Internal error: CMake generator name is empty. Pass -Generator explicitly."
}

$cacheFile = Join-Path $VanillaBuild "CMakeCache.txt"
if (Test-Path -LiteralPath $cacheFile) {
  $cachedLine = Get-Content -LiteralPath $cacheFile -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '^CMAKE_GENERATOR:INTERNAL=' } |
    Select-Object -First 1
  if ($cachedLine) {
    $cachedGen = ($cachedLine -replace '^CMAKE_GENERATOR:INTERNAL=', '').Trim()
    if ($cachedGen -ne $gen) {
      Write-Host "Existing build used generator '$cachedGen'; this run uses '$gen'. Removing $VanillaBuild" -ForegroundColor Yellow
      Remove-Item -LiteralPath $VanillaBuild -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

New-Item -ItemType Directory -Force -Path $VanillaBuild | Out-Null
Push-Location $VanillaBuild
try {
  if ($gen -match "Ninja") {
    cmake -G $gen -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=/utf-8 -DCMAKE_C_FLAGS=/utf-8 ..
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
    & ninja rocksdb
    if ($LASTEXITCODE -ne 0) { throw "ninja rocksdb failed" }
  } else {
    function Invoke-CmakeConfigure {
      param([string]$G, [string]$Instance)
      $args = @("-G", $G)
      if ($G -eq "NMake Makefiles") {
        $args += "-DCMAKE_BUILD_TYPE=Release"
      } else {
        $args += "-A", "x64"
      }
      $args += "-DCMAKE_CXX_FLAGS=/utf-8", "-DCMAKE_C_FLAGS=/utf-8"
      if (-not [string]::IsNullOrWhiteSpace($Instance)) {
        $args += "-DCMAKE_GENERATOR_INSTANCE=$Instance"
      }
      $args += ".."
      Write-Host "cmake $($args -join ' ')" -ForegroundColor DarkGray
      & cmake @args
      return $LASTEXITCODE
    }

    $configured = $false
    if (-not [string]::IsNullOrWhiteSpace($vsInstance)) {
      if ((Invoke-CmakeConfigure -G $gen -Instance $vsInstance) -eq 0) {
        $configured = $true
      }
    }
    if (-not $configured) {
      $vsList = @(Get-VisualStudioCmakeCandidates -PreferredVsRoot $VsInstallRoot)
      foreach ($c in $vsList) {
        $gCand = if ($c -is [hashtable]) { [string]$c['Generator'] } else { [string]$c.Generator }
        $iCand = if ($c -is [hashtable]) { [string]$c['Instance'] } else { [string]$c.Instance }
        if ([string]::IsNullOrWhiteSpace($gCand)) {
          continue
        }
        if ((Invoke-CmakeConfigure -G $gCand -Instance $iCand) -eq 0) {
          $configured = $true
          break
        }
      }
    }
    if (-not $configured) {
      if ((Invoke-CmakeConfigure -G $gen -Instance $null) -eq 0) {
        $configured = $true
      }
    }
    if (-not $configured) {
      $cl = Get-Command cl -ErrorAction SilentlyContinue
      if ($cl) {
        Write-Host "Trying NMake Makefiles (cl.exe is on PATH)..." -ForegroundColor Yellow
        if ((Invoke-CmakeConfigure -G "NMake Makefiles" -Instance $null) -eq 0) {
          $configured = $true
        }
      }
    }
    if (-not $configured) {
      throw @"
cmake could not find a working Visual Studio generator.

Fix one of:
  1) Install "Desktop development with C++" (VS or Build Tools): https://visualstudio.microsoft.com/downloads/
  2) Open **x64 Native Tools Command Prompt for VS** (or run VsDevCmd), then re-run this script — NMake or vswhere may work.
  3) Add Ninja to PATH (same prompt as cl), then re-run; script will use Ninja.
  4) Pass -Generator `"Visual Studio 17 2022`" and ensure CMake lists that generator (cmake --help).

If VS is on a custom drive, pass the install root (folder that contains `VC\`):
  -VsInstallRoot `"D:\Visio`"
or set `$env:CMAKE_GENERATOR_INSTANCE` and use -Generator matching your VS year (see cmake --help).
"@
    }
    cmake --build . --config Release --parallel --target rocksdb
    if ($LASTEXITCODE -ne 0) { throw "cmake --build rocksdb failed" }
  }
} finally {
  Pop-Location
}

$libRelease = Join-Path $VanillaBuild "Release\rocksdb.lib"
$libRoot = Join-Path $VanillaBuild "rocksdb.lib"
$libChosen = $null
if (Test-Path $libRelease) {
  $libChosen = $libRelease
  Write-Host "Done: $libRelease (Visual Studio layout)" -ForegroundColor Green
} elseif (Test-Path $libRoot) {
  $libChosen = $libRoot
  Write-Host "Done: $libRoot" -ForegroundColor Green
} else {
  Write-Warning "Build finished but rocksdb.lib not found at expected paths; search under $VanillaBuild"
}
if ($libChosen) {
  $bytes = (Get-Item -LiteralPath $libChosen).Length
  if ($bytes -eq 0) {
    throw @"
rocksdb.lib is 0 bytes at $libChosen — the static library was not produced (link step failed or was skipped).
Remove the build tree and rebuild:
  Remove-Item -Recurse -Force `"$VanillaBuild`"
  powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\bootstrap_rocksdb_vanilla.ps1`"
"@
  }
  if ($bytes -lt 65536) {
    Write-Warning "rocksdb.lib is only $bytes bytes — if rocks-demo link fails with LNK1136, delete `"$VanillaBuild`" and re-run this script."
  }
}
