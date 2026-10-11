# build-sbpf.ps1 — Build a Solana sBPF on-chain program (.so) with Sig.
#
# Mirrors the android `build-lib -dynamic -target ... -femit-bin=...so` driver
# shape, but with NO external SDK: it is a pure `sig` invocation and therefore
# works on Windows (the primary dev host) and every Sig host. The Solana CLI /
# solana-test-validator is only needed to DEPLOY the resulting .so, never to
# produce it (see compiler/SBPF_SOLANA_TARGET.md §8).
#
# Usage:
#   .\tools\build-sbpf.ps1 -Entry .build\sbpf-test\entry.sig -Out program.so
#
# Parameters:
#   -Entry    Path to the root .sig module exporting
#             `export fn entrypoint(input: [*]u8) callconv(.c) u64`.
#   -Out      Output shared-object path (default: program.so).
#   -Mcpu     sBPF version CPU model (default: sbpfv3).
#   -Optimize Optimization mode (default: ReleaseSmall).
#   -Sig      Path to the sig compiler (default: auto-detect on PATH).
#   -Dep      Optional array of "name=path" module declarations wired via
#             --dep/-M, matching the android driver's module wiring. The actual
#             on-chain modules are zpm's job; this is just the plumbing.
#
# The sBPF target forces the self-hosted ELF linker and defaults to
# no-compiler_rt, so no extra flags are required beyond the ones below.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]   $Entry,
    [string]   $Out      = "program.so",
    [string]   $Mcpu     = "sbpfv3",
    [string]   $Optimize = "ReleaseSmall",
    [string]   $Sig      = "",
    [string[]] $Dep      = @()
)

$ErrorActionPreference = 'Stop'

# ── Locate the sig compiler ──────────────────────────────────────────────────
if (-not $Sig) {
    if ($env:SIG_COMPILER) {
        $Sig = $env:SIG_COMPILER
    } elseif (Get-Command "sig" -ErrorAction SilentlyContinue) {
        $Sig = "sig"
    } else {
        Write-Error "error: sig compiler not found. Put it on PATH or set `$env:SIG_COMPILER / -Sig."
        exit 1
    }
}

if (-not (Test-Path $Entry)) {
    Write-Error "error: entry source not found: $Entry"
    exit 1
}

# ── Compose the invocation ───────────────────────────────────────────────────
# build-lib -dynamic -target sbf-solana-solana -mcpu <ver> -O <mode>
#   -femit-bin=<out> [--dep name -Mname=path ...] <entry>
$sigArgs = @(
    "build-lib",
    "-dynamic",
    "-target", "sbf-solana-solana",
    "-mcpu", $Mcpu,
    "-O", $Optimize,
    "-femit-bin=$Out"
)

# Optional module wiring (same pattern as build-android.ps1's --dep/-M).
foreach ($d in $Dep) {
    $name, $path = $d -split '=', 2
    if (-not $path) { Write-Error "error: -Dep entry must be 'name=path': $d"; exit 1 }
    $sigArgs += @("--dep", $name, "-M$name=$path")
}

# Root module is the final positional (build-lib takes the root positionally).
$sigArgs += $Entry

Write-Host "Building sBPF program..."
Write-Host "  compiler: $Sig"
Write-Host "  entry:    $Entry"
Write-Host "  target:   sbf-solana-solana  (-mcpu $Mcpu, -O $Optimize)"
Write-Host "  output:   $Out"
Write-Host ""
Write-Host "  $Sig $($sigArgs -join ' ')"
Write-Host ""

& $Sig @sigArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "`nerror: sBPF link failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}

if (-not (Test-Path $Out)) {
    Write-Error "error: expected output $Out was not produced."
    exit 1
}

Write-Host ""
Write-Host "Done: $Out"
Write-Host "Deploy under WSL: solana program deploy $Out"
Write-Host "(See compiler/SBPF_SOLANA_TARGET.md for the full deploy recipe.)"
