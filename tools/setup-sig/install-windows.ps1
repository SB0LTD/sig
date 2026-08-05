#!/usr/bin/env pwsh
# setup-sig: Install or validate a sig installation on Windows.
#
# Usage:
#   .\install-windows.ps1                    # Validate existing installation
#   .\install-windows.ps1 -Install <path>    # Install from release archive
#   .\install-windows.ps1 -FromRelease       # Download latest and install
#
# The sig installation layout:
#   <prefix>/
#   ├── bin/sig.exe
#   └── lib/
#       ├── std/           (zig standard library)
#       ├── sig/           (sig standard library modules)
#       ├── compiler/      (Maker.zig, configurer.zig, aro/)
#       └── tools/
#           └── sig_build/ (sig-native build runner)

param(
    [string]$Install,
    [switch]$FromRelease,
    [string]$Prefix = "C:\Just-Things\Projects\Lib\sig-bin"
)

$ErrorActionPreference = "Stop"

function Test-SigInstallation {
    param([string]$Root)

    $errors = @()
    $warnings = @()

    # Check binary exists
    $sigExe = Join-Path $Root "bin\sig.exe"
    if (-not (Test-Path $sigExe)) {
        $errors += "Missing: bin\sig.exe"
    } else {
        # Check version
        try {
            $ver = & $sigExe version 2>&1
            Write-Host "  Binary version: $ver" -ForegroundColor Green
        } catch {
            $warnings += "sig.exe exists but failed to run: $_"
        }
    }

    # Check lib directory structure
    $libDir = Join-Path $Root "lib"
    $requiredPaths = @(
        "std\std.zig",
        "std\lang.zig",
        "sig\sig.sig",
        "sig\containers.sig",
        "compiler\Maker.zig",
        "compiler\configurer.zig",
        "compiler\aro\aro.zig",
        "tools\sig_build\main.sig",
        "tools\sig_build\build_host.sig",
        "tools\sig_build\cli.sig"
    )

    foreach ($rel in $requiredPaths) {
        $full = Join-Path $libDir $rel
        if (-not (Test-Path $full)) {
            $errors += "Missing: lib\$rel"
        }
    }

    # Check for stale .zig files in lib/sig/ (should be .sig)
    $sigLibDir = Join-Path $libDir "sig"
    if (Test-Path $sigLibDir) {
        $zigFiles = Get-ChildItem $sigLibDir -Filter "*.zig" -ErrorAction SilentlyContinue
        $sigFiles = Get-ChildItem $sigLibDir -Filter "*.sig" -ErrorAction SilentlyContinue
        if ($zigFiles.Count -gt 0 -and $sigFiles.Count -eq 0) {
            $errors += "lib\sig\ contains .zig files but no .sig files (stale distribution)"
        }
    }

    # Check env var
    $envLib = [Environment]::GetEnvironmentVariable("ZIG_LIB_DIR", "User")
    if ($envLib -and $envLib -ne $libDir) {
        $warnings += "ZIG_LIB_DIR env var ($envLib) does not match installation lib ($libDir)"
    }

    # Report
    Write-Host ""
    if ($errors.Count -eq 0) {
        Write-Host "  Installation OK ($($requiredPaths.Count) critical files verified)" -ForegroundColor Green
    } else {
        Write-Host "  ERRORS ($($errors.Count)):" -ForegroundColor Red
        foreach ($e in $errors) { Write-Host "    - $e" -ForegroundColor Red }
    }
    if ($warnings.Count -gt 0) {
        Write-Host "  WARNINGS ($($warnings.Count)):" -ForegroundColor Yellow
        foreach ($w in $warnings) { Write-Host "    - $w" -ForegroundColor Yellow }
    }

    return $errors.Count -eq 0
}

function Sync-FromSource {
    param([string]$Root, [string]$SigRepo)

    Write-Host "Syncing lib from sig source repo..." -ForegroundColor Cyan
    $libDest = Join-Path $Root "lib"

    # Use robocopy for fast sync
    $null = & cmd /c "robocopy `"$SigRepo\lib`" `"$libDest`" /E /NFL /NDL /NJH /NJS /NC /NS /NP /PURGE"

    # Copy tools/sig_build into lib/tools/sig_build
    $toolsSrc = Join-Path $SigRepo "tools\sig_build"
    $toolsDest = Join-Path $libDest "tools\sig_build"
    New-Item -ItemType Directory -Path $toolsDest -Force | Out-Null
    $null = & cmd /c "robocopy `"$toolsSrc`" `"$toolsDest`" /E /NFL /NDL /NJH /NJS /NC /NS /NP /PURGE"

    Write-Host "  Done." -ForegroundColor Green
}

# Main
Write-Host "sig installation validator" -ForegroundColor Cyan
Write-Host "  Prefix: $Prefix"
Write-Host ""

$sigRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($Install) {
    Write-Host "Installing from archive: $Install"
    # TODO: Extract and install
    Write-Host "Not yet implemented - use Sync-FromSource for now"
} elseif ($FromRelease) {
    Write-Host "Downloading latest release..."
    # TODO: gh release download
    Write-Host "Not yet implemented - use Sync-FromSource for now"
} else {
    # Validate mode
    $ok = Test-SigInstallation -Root $Prefix
    if (-not $ok) {
        Write-Host ""
        Write-Host "  Attempting auto-fix from source repo at: $sigRepo" -ForegroundColor Yellow
        if (Test-Path (Join-Path $sigRepo "lib\std\std.zig")) {
            Sync-FromSource -Root $Prefix -SigRepo $sigRepo
            Write-Host ""
            Write-Host "  Re-validating..." -ForegroundColor Cyan
            $ok = Test-SigInstallation -Root $Prefix
        } else {
            Write-Host "  Source repo not found. Cannot auto-fix." -ForegroundColor Red
        }
    }
    exit ([int](-not $ok))
}
