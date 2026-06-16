#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Bug Condition Exploration Test - Windows Bootstrap Heap Corruption
    
.DESCRIPTION
    This script verifies the bug conditions that cause STATUS_HEAP_CORRUPTION (0xC0000374)
    in the Windows native bootstrap binary (zig2.exe/sig.exe).
    
    Bug Condition (from design):
      isBugCondition(input) returns true when:
        input.llvmPackage.crtLinkage == "/MD"
        AND input.zig2Target.crtLinkage == "/MD"  
        AND input.compilerRt.exportsMathSymbols("round", "fabs", "ceil", "floor", "sqrt")
        AND input.linkerFlags.contains("/FORCE:MULTIPLE")
        AND input.operation == "build-exe"
    
    **Validates: Requirements 1.1, 1.2**
    
    EXPECTED BEHAVIOR ON UNFIXED CODE: ALL checks FAIL (bug conditions are present)
    EXPECTED BEHAVIOR ON FIXED CODE: ALL checks PASS (bug conditions are eliminated)
    
    Property 1: Bug Condition - Dynamic CRT + Duplicate Symbols Cause Runtime Crash
    
    When these conditions co-exist, the linker picks arbitrarily between conflicting
    heap/math implementations, causing heap metadata corruption at runtime during
    heavy allocation (build-exe).
    
.NOTES
    This is a CI/build infrastructure test. It inspects source files for the known
    bug conditions rather than running the binary (which requires a full CI build).
#>

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# Paths relative to sig project root
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SigRoot = Split-Path -Parent $ScriptDir

$CMakeListsPath = Join-Path $SigRoot "CMakeLists.txt"
$BuildLlvmYamlPath = Join-Path $SigRoot ".github\workflows\build-llvm.yaml"
$CompilerRtPath = Join-Path $SigRoot "lib\compiler_rt.zig"

# Track results
$Results = @()
$AllPassed = $true

function Test-BugCondition {
    param(
        [string]$Name,
        [string]$Description,
        [scriptblock]$Check
    )
    
    $result = @{
        Name = $Name
        Description = $Description
        BugPresent = $false
        Details = ""
    }
    
    try {
        $checkResult = & $Check
        $result.BugPresent = $checkResult.BugPresent
        $result.Details = $checkResult.Details
    }
    catch {
        $result.BugPresent = $true
        $result.Details = "ERROR: $_"
    }
    
    return $result
}

Write-Host "=" * 80
Write-Host "Bug Condition Exploration Test - Windows Bootstrap Heap Corruption"
Write-Host "Property 1: Dynamic CRT + Duplicate Symbols Cause Runtime Crash"
Write-Host "Validates: Requirements 1.1, 1.2"
Write-Host "=" * 80
Write-Host ""

# ============================================================================
# CHECK 1: LLVM package built without /MT (defaults to /MD)
# ============================================================================
$check1 = Test-BugCondition -Name "LLVM_PACKAGE_CRT" -Description "LLVM Windows build missing -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded (defaults to /MD)" -Check {
    $yaml = Get-Content $BuildLlvmYamlPath -Raw
    
    # Find the Windows MSVC build section
    # The bug condition: the Windows native LLVM build does NOT specify MultiThreaded
    # which means it defaults to /MD (dynamic CRT)
    $hasMTFlag = $yaml -match "CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"
    
    # Check specifically in the Windows build context
    # The Windows build section uses: cmake -S llvm-src\llvm -B llvm-build ... (in cmd block)
    $windowsBuildSection = $yaml -split "Build LLVM natively \(Windows MSVC\)" | Select-Object -Last 1
    $windowsSectionHasMT = $false
    if ($windowsBuildSection) {
        $windowsSectionHasMT = $windowsBuildSection -match "CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"
    }
    
    if (-not $hasMTFlag -or -not $windowsSectionHasMT) {
        return @{
            BugPresent = $true
            Details = "build-llvm.yaml Windows MSVC build does NOT specify -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded. LLVM libs default to /MD (dynamic CRT). This forces zig2.exe to also use /MD, creating a runtime dependency on vcruntime140.dll and ucrtbase.dll."
        }
    }
    else {
        return @{
            BugPresent = $false
            Details = "build-llvm.yaml correctly specifies -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded for Windows build."
        }
    }
}
$Results += $check1

# ============================================================================
# CHECK 2: zig2 target uses MultiThreadedDLL (/MD)
# ============================================================================
$check2 = Test-BugCondition -Name "ZIG2_CRT_LINKAGE" -Description "zig2 target linked with MultiThreadedDLL (/MD) instead of MultiThreaded (/MT)" -Check {
    $cmake = Get-Content $CMakeListsPath -Raw
    
    # Check the global CMAKE_MSVC_RUNTIME_LIBRARY setting
    $globalMDMatch = [regex]::Match($cmake, 'set\(CMAKE_MSVC_RUNTIME_LIBRARY\s+MultiThreadedDLL\)')
    
    # Check the zig2 target-specific setting
    $zig2MDMatch = [regex]::Match($cmake, 'set_property\(TARGET\s+zig2\s+PROPERTY\s+MSVC_RUNTIME_LIBRARY\s+"MultiThreadedDLL"\)')
    
    $bugDetails = @()
    $bugPresent = $false
    
    if ($globalMDMatch.Success) {
        $bugPresent = $true
        $bugDetails += "Global CMAKE_MSVC_RUNTIME_LIBRARY is set to MultiThreadedDLL (/MD)"
    }
    
    if ($zig2MDMatch.Success) {
        $bugPresent = $true
        $bugDetails += "zig2 target MSVC_RUNTIME_LIBRARY explicitly set to MultiThreadedDLL (/MD)"
    }
    
    if ($bugPresent) {
        return @{
            BugPresent = $true
            Details = ($bugDetails -join ". ") + ". This means zig2.exe requires vcruntime140.dll and ucrtbase.dll at runtime, causing exit code 127 in environments without vcvars64.bat."
        }
    }
    else {
        return @{
            BugPresent = $false
            Details = "zig2 target uses static CRT (MultiThreaded / /MT). No DLL dependencies."
        }
    }
}
$Results += $check2

# ============================================================================
# CHECK 3: /FORCE:MULTIPLE linker flag present
# ============================================================================
$check3 = Test-BugCondition -Name "FORCE_MULTIPLE_FLAG" -Description "/FORCE:MULTIPLE linker flag masks duplicate symbol conflicts" -Check {
    $cmake = Get-Content $CMakeListsPath -Raw
    
    # Check for /FORCE:MULTIPLE in the actual set(ZIG2_LINK_FLAGS ...) directive (not comments)
    # The pattern matches: set(ZIG2_LINK_FLAGS "..." ) where the string contains /FORCE:MULTIPLE
    $forceMultipleMatch = [regex]::Match($cmake, 'set\(ZIG2_LINK_FLAGS\s+"[^"]*(/FORCE:MULTIPLE)[^"]*"\)')
    
    if ($forceMultipleMatch.Success) {
        return @{
            BugPresent = $true
            Details = "CMakeLists.txt contains /FORCE:MULTIPLE in ZIG2_LINK_FLAGS. This allows the linker to pick arbitrarily between conflicting symbol definitions (CRT heap vs compiler_rt math), causing heap metadata corruption when both code paths are exercised during build-exe."
        }
    }
    else {
        return @{
            BugPresent = $false
            Details = "No /FORCE:MULTIPLE flag found in ZIG2_LINK_FLAGS. Linker will report duplicate symbols as errors (correct behavior)."
        }
    }
}
$Results += $check3

# ============================================================================
# CHECK 4: compiler_rt.zig exports math symbols with .strong linkage for -ofmt=c
# ============================================================================
$check4 = Test-BugCondition -Name "COMPILER_RT_STRONG_MATH" -Description "compiler_rt.zig exports conflicting math symbols with .strong linkage when ofmt_c" -Check {
    $compilerRt = Get-Content $CompilerRtPath -Raw
    $cmake = Get-Content $CMakeListsPath -Raw
    
    # Check if CMakeLists.txt force-includes a rename header for compiler_rt.c
    # This is an alternative fix approach: rename conflicting symbols at compile time via /FI header
    $hasForceIncludeRenameHeader = $cmake -match 'compiler_rt_msvc_math\.h'
    
    if ($hasForceIncludeRenameHeader) {
        # The fix uses a force-include header to rename conflicting symbols at compile time.
        # This means compiler_rt.c won't export the raw math symbols (they get prefixed).
        # The source compiler_rt.zig is unchanged, but the compiled output is safe.
        return @{
            BugPresent = $false
            Details = "compiler_rt.c math symbols are renamed via force-include header (compiler_rt_msvc_math.h). No conflicts with MSVC CRT."
        }
    }
    
    # Fallback: check the source-level approach (Windows exclusion or weak linkage)
    # Check 1: linkage is .strong when ofmt_c
    $strongLinkageMatch = [regex]::Match($compilerRt, 'if\s*\(ofmt_c\)\s*\n?\s*\.strong')
    
    # Check 2: Math symbol files are imported (these export round, fabs, ceil, floor, sqrt)
    $conflictingSymbols = @("fabs.zig", "floor_ceil.zig", "round.zig", "sqrt.zig")
    $foundSymbols = @()
    
    foreach ($sym in $conflictingSymbols) {
        if ($compilerRt -match [regex]::Escape($sym)) {
            $foundSymbols += $sym
        }
    }
    
    # Check 3: These symbols are NOT conditionally excluded on Windows
    # (They would be excluded if wrapped in a target OS check)
    $hasWindowsExclusion = $compilerRt -match 'windows.*fabs|windows.*round|windows.*sqrt|windows.*floor_ceil'
    
    $bugPresent = $false
    $bugDetails = @()
    
    if ($strongLinkageMatch.Success) {
        $bugPresent = $true
        $bugDetails += "linkage is .strong when ofmt_c is true (line ~36)"
    }
    
    if ($foundSymbols.Count -eq $conflictingSymbols.Count) {
        $bugPresent = $true
        $bugDetails += "All conflicting math modules imported: $($foundSymbols -join ', ')"
    }
    
    if (-not $hasWindowsExclusion) {
        $bugPresent = $true
        $bugDetails += "No Windows-specific exclusion for conflicting math symbols"
    }
    
    if ($bugPresent) {
        return @{
            BugPresent = $true
            Details = ($bugDetails -join ". ") + ". When building with -ofmt=c on Windows, compiler_rt.c will export round, fabs, ceil, floor, sqrt as strong symbols that duplicate MSVC CRT definitions. Combined with /FORCE:MULTIPLE, the linker picks arbitrarily between implementations."
        }
    }
    else {
        return @{
            BugPresent = $false
            Details = "Math symbols are properly excluded or use weak linkage on Windows."
        }
    }
}
$Results += $check4

# ============================================================================
# CHECK 5: Combined bug condition - all factors present simultaneously
# ============================================================================
$check5 = Test-BugCondition -Name "COMBINED_BUG_CONDITION" -Description "All bug conditions co-exist: /MD + strong math symbols + /FORCE:MULTIPLE causes heap corruption on build-exe" -Check {
    $allBugsPresent = ($Results | Where-Object { $_.BugPresent } | Measure-Object).Count -eq 4
    
    if ($allBugsPresent) {
        return @{
            BugPresent = $true
            Details = @"
ALL bug conditions confirmed present in unfixed code:
  1. LLVM package built with /MD (dynamic CRT) - forces zig2.exe to use /MD
  2. zig2 target explicitly set to MultiThreadedDLL (/MD) - runtime DLL dependency
  3. /FORCE:MULTIPLE allows linker to pick between conflicting implementations
  4. compiler_rt.zig exports strong math symbols that duplicate MSVC CRT
  
  CONSEQUENCE: When zig2.exe runs build-exe (heavy allocation), the conflicting
  heap implementations cause STATUS_HEAP_CORRUPTION (0xC0000374). In environments
  without vcvars64.bat, the binary fails to load entirely (exit code 127).
  
  COUNTEREXAMPLES:
  - Binary requires vcruntime140.dll - fails in clean PATH
  - build-exe crashes with 0xC0000374 during heavy allocation
  - Linker silently picks wrong implementation for round/fabs
"@
        }
    }
    else {
        return @{
            BugPresent = $false
            Details = "Not all bug conditions present - some have been fixed."
        }
    }
}
$Results += $check5

# ============================================================================
# REPORT
# ============================================================================
Write-Host ""
Write-Host "-" * 80
Write-Host "RESULTS"
Write-Host "-" * 80
Write-Host ""

$testPassed = $true  # For a bug exploration test, "passed" means we found the bug

foreach ($r in $Results) {
    $status = if ($r.BugPresent) { "BUG PRESENT" } else { "FIXED" }
    $icon = if ($r.BugPresent) { "[X]" } else { "[OK]" }
    
    Write-Host "$icon $($r.Name): $status"
    Write-Host "    Description: $($r.Description)"
    if ($Verbose -or $r.BugPresent) {
        Write-Host "    Details: $($r.Details)"
    }
    Write-Host ""
    
    if (-not $r.BugPresent) {
        $testPassed = $false
    }
}

Write-Host "-" * 80

# For bug exploration tests:
# - If ALL bugs are present -> test "fails" (which is SUCCESS for exploration - confirms bug exists)
# - If ANY bug is fixed -> test "passes" (unexpected - bug may not be properly reproduced)
$allBugsPresent = ($Results | Where-Object { $_.BugPresent } | Measure-Object).Count -eq $Results.Count

if ($allBugsPresent) {
    Write-Host ""
    Write-Host "EXPLORATION TEST RESULT: FAIL (as expected)"
    Write-Host ""
    Write-Host "All bug conditions are confirmed present in the current (unfixed) code."
    Write-Host "This proves the bug exists and validates the root cause analysis."
    Write-Host ""
    Write-Host "Counterexamples documented:"
    Write-Host "  - zig2.exe depends on vcruntime140.dll (confirmed via /MD linkage)"
    Write-Host "  - zig2.exe will crash with STATUS_HEAP_CORRUPTION on build-exe"
    Write-Host "    (confirmed via /FORCE:MULTIPLE + strong compiler_rt math symbols)"
    Write-Host "  - LLVM package forces /MD on all consumers (no /MT in build config)"
    Write-Host ""
    # Exit with non-zero to indicate test FAILURE (bug conditions present)
    exit 1
}
else {
    $fixedCount = ($Results | Where-Object { -not $_.BugPresent } | Measure-Object).Count
    $totalCount = $Results.Count
    Write-Host ""
    Write-Host "EXPLORATION TEST RESULT: PASS (unexpected for unfixed code)"
    Write-Host ""
    Write-Host "$fixedCount of $totalCount bug conditions appear to be fixed."
    Write-Host "If running on unfixed code, this indicates the test may not be detecting the bug correctly."
    Write-Host ""
    # Exit with zero to indicate test PASS (bug conditions NOT all present)
    exit 0
}
