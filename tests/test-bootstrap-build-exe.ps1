#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Reproduction test for Windows bootstrap heap corruption (STATUS_HEAP_CORRUPTION 0xC0000374).

.DESCRIPTION
    This script builds zig2.exe locally using cmake + clang-cl + LLVM 22, then
    runs it to compile a real program (sig itself). This is the exact reproduction
    of the bug: zig2.exe works for `version` but crashes during `build-exe`.

    PREREQUISITES:
    - Visual Studio 2022 with C++ workload (provides clang-cl, lld-link)
    - LLVM 22 native Windows package downloaded to .\llvm-22\ (or specify -LlvmPrefix)
    - Run from the sig repo root

    EXPECTED BEHAVIOR:
    - BEFORE FIX: zig2.exe version works, zig2.exe build-exe crashes with 0xC0000374
    - AFTER FIX:  zig2.exe version works, zig2.exe build-exe succeeds

.PARAMETER LlvmPrefix
    Path to the LLVM 22 installation directory. Default: .\llvm-22

.PARAMETER SkipBuild
    Skip the cmake build step (use existing build\zig2.exe)

.PARAMETER BuildOnly
    Only build zig2.exe, don't test build-exe
#>

param(
    [string]$LlvmPrefix = ".\llvm-22",
    [switch]$SkipBuild,
    [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"
$SigRoot = $PSScriptRoot | Split-Path -Parent

Push-Location $SigRoot
try {
    Write-Host "=" * 70
    Write-Host "Windows Bootstrap Heap Corruption Test"
    Write-Host "Reproduction: zig2.exe build-exe crashes with STATUS_HEAP_CORRUPTION"
    Write-Host "=" * 70
    Write-Host ""

    # ─── Step 1: Verify prerequisites ───────────────────────────────────────
    Write-Host "[1/5] Checking prerequisites..."

    if (-not (Test-Path $LlvmPrefix)) {
        Write-Host "ERROR: LLVM 22 not found at $LlvmPrefix"
        Write-Host "Download from: gh release download llvm-22 --pattern llvm-22-x86_64-windows-native.tar.zst"
        exit 1
    }

    $vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $vcvars)) {
        $vcvars = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    }
    if (-not (Test-Path $vcvars)) {
        Write-Host "ERROR: vcvars64.bat not found (need VS 2022)"
        exit 1
    }

    Write-Host "  LLVM: $LlvmPrefix"
    Write-Host "  vcvars: $vcvars"
    Write-Host ""

    # ─── Step 2: Build zig2.exe ─────────────────────────────────────────────
    if (-not $SkipBuild) {
        Write-Host "[2/5] Building zig2.exe with cmake + clang-cl..."

        if (Test-Path "build") { Remove-Item -Recurse -Force "build" }
        mkdir build | Out-Null

        $buildScript = @"
call "$vcvars"
set PATH=$($SigRoot)\llvm-22\bin;%PATH%
cd build
cmake .. -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl -DCMAKE_LINKER=lld-link -DCMAKE_PREFIX_PATH=$LlvmPrefix -DCMAKE_BUILD_TYPE=Release -DZIG_USE_LLVM_CONFIG=ON -DZIG_NO_LIB=ON -DZIG_TARGET_MCPU=baseline -GNinja
ninja zig2 -j%NUMBER_OF_PROCESSORS%
"@
        $buildScript | Set-Content "build\_run.cmd" -Encoding ASCII
        $proc = Start-Process cmd.exe -ArgumentList "/c build\_run.cmd" -NoNewWindow -PassThru -Wait
        if ($proc.ExitCode -ne 0) {
            Write-Host "FAIL: cmake build failed with exit code $($proc.ExitCode)"
            exit 1
        }

        if (-not (Test-Path "build\zig2.exe")) {
            Write-Host "FAIL: zig2.exe not produced"
            exit 1
        }
        Write-Host "  OK: zig2.exe built successfully"
    } else {
        Write-Host "[2/5] Skipping build (using existing build\zig2.exe)"
        if (-not (Test-Path "build\zig2.exe")) {
            Write-Host "FAIL: build\zig2.exe not found. Run without -SkipBuild first."
            exit 1
        }
    }
    Write-Host ""

    # ─── Step 3: Test zig2.exe version ──────────────────────────────────────
    Write-Host "[3/5] Testing: zig2.exe version..."
    $proc = Start-Process "build\zig2.exe" -ArgumentList "version" -NoNewWindow -PassThru -Wait
    if ($proc.ExitCode -ne 0) {
        Write-Host "FAIL: zig2.exe version exited with code $($proc.ExitCode)"
        if ($proc.ExitCode -eq -1073740940 -or $proc.ExitCode -eq 0xC0000374) {
            Write-Host "  STATUS_HEAP_CORRUPTION on version command (very broken)"
        }
        exit 1
    }
    Write-Host "  OK: version command succeeded"
    Write-Host ""

    if ($BuildOnly) {
        Write-Host "BUILD ONLY mode - skipping build-exe test"
        Write-Host "PASS (build succeeded)"
        exit 0
    }

    # ─── Step 4: Test zig2.exe build-exe (THE REPRODUCTION) ─────────────────
    Write-Host "[4/5] Testing: zig2.exe build-exe (heap corruption reproduction)..."
    Write-Host "  This compiles sig from source using the bootstrap binary."
    Write-Host "  BEFORE FIX: crashes with STATUS_HEAP_CORRUPTION (0xC0000374)"
    Write-Host "  AFTER FIX:  succeeds"
    Write-Host ""

    # Generate build_options.zig
    $buildGen = ".build-gen"
    if (-not (Test-Path $buildGen)) { mkdir $buildGen | Out-Null }
    @"
pub const have_llvm: bool = false;
pub const llvm_has_m68k: bool = false;
pub const llvm_has_csky: bool = false;
pub const llvm_has_arc: bool = false;
pub const llvm_has_xtensa: bool = false;
pub const enable_logging: bool = false;
pub const enable_debug_extensions: bool = false;
pub const enable_link_snapshots: bool = false;
pub const debug_gpa: bool = false;
pub const enable_tracy: bool = false;
pub const enable_tracy_callstack: bool = false;
pub const enable_tracy_allocation: bool = false;
pub const tracy_callstack_depth: u32 = 6;
pub const value_tracing: bool = false;
pub const mem_leak_frames: u32 = 0;
pub const io_mode: enum { threaded, evented } = .threaded;
pub const value_interpret_mode: enum { direct, by_name } = .direct;
pub const version: [:0]const u8 = "0.17.0";
pub const sig_version: [:0]const u8 = "test";
pub const semver: @import("std").SemanticVersion = .{ .major = 0, .minor = 17, .patch = 0 };
pub const dev: enum { full, bootstrap, ast_gen, sema, cbe, @"aarch64-linux", @"powerpc-linux", @"riscv64-linux", spirv, wasm, @"x86_64-linux" } = .full;
"@ | Set-Content "$buildGen\build_options.zig" -Encoding UTF8

    if (-not (Test-Path "stage3-out\bin")) { mkdir "stage3-out\bin" -Force | Out-Null }

    # Run the actual build-exe command — THIS IS THE REPRODUCTION
    $buildExeScript = @"
call "$vcvars"
build\zig2.exe build-exe --dep build_options --dep aro -Mroot=src/main.zig -Mbuild_options=.build-gen/build_options.zig -Maro=lib/compiler/aro/aro.zig --name sig -OReleaseSafe --zig-lib-dir lib --cache-dir .zig-cache -femit-bin=stage3-out/bin/sig.exe
"@
    $buildExeScript | Set-Content "build\_run_buildexe.cmd" -Encoding ASCII
    $proc = Start-Process cmd.exe -ArgumentList "/c build\_run_buildexe.cmd" -NoNewWindow -PassThru -Wait
    
    if ($proc.ExitCode -eq -1073740940) {
        Write-Host ""
        Write-Host "FAIL: STATUS_HEAP_CORRUPTION (0xC0000374)"
        Write-Host ""
        Write-Host "  The bootstrap binary crashed during build-exe."
        Write-Host "  This is the heap corruption bug — malloc/free/realloc conflicts"
        Write-Host "  between zig2.c declarations and MSVC CRT."
        Write-Host ""
        exit 1
    }
    elseif ($proc.ExitCode -ne 0) {
        Write-Host ""
        Write-Host "FAIL: build-exe exited with code $($proc.ExitCode) (0x$($proc.ExitCode.ToString('X8')))"
        Write-Host ""
        exit 1
    }
    
    Write-Host "  OK: build-exe succeeded without crash!"
    Write-Host ""

    # ─── Step 5: Verify output binary ───────────────────────────────────────
    Write-Host "[5/5] Verifying output binary..."
    if (-not (Test-Path "stage3-out\bin\sig.exe")) {
        Write-Host "FAIL: sig.exe not produced"
        exit 1
    }
    $size = (Get-Item "stage3-out\bin\sig.exe").Length / 1MB
    Write-Host "  sig.exe size: $([math]::Round($size, 1)) MB"
    
    $proc = Start-Process "stage3-out\bin\sig.exe" -ArgumentList "version" -NoNewWindow -PassThru -Wait
    if ($proc.ExitCode -eq 0) {
        Write-Host "  OK: output sig.exe runs 'version' successfully"
    } else {
        Write-Host "  WARNING: sig.exe version returned $($proc.ExitCode) (may need lib/ next to binary)"
    }
    Write-Host ""

    # ─── Result ─────────────────────────────────────────────────────────────
    Write-Host "=" * 70
    Write-Host "PASS: Bootstrap builds and runs build-exe without heap corruption"
    Write-Host "=" * 70
    exit 0

} finally {
    Pop-Location
}
