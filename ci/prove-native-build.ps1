param(
    [Parameter(Mandatory = $true)][string]$Sig,
    [Parameter(Mandatory = $true)][string]$ZigLibDir
)

$ErrorActionPreference = 'Stop'
$sigPath = (Resolve-Path -LiteralPath $Sig).Path
$libPath = (Resolve-Path -LiteralPath $ZigLibDir).Path
$fixture = Join-Path $PSScriptRoot 'fixtures\native-build\build.sig'
$proofRoot = Join-Path $env:RUNNER_TEMP ("sig-native-build-proof-" + [guid]::NewGuid().ToString('N'))
$defaultProject = Join-Path $proofRoot 'default'
$customProject = Join-Path $proofRoot 'custom'
New-Item -ItemType Directory -Force $defaultProject, $customProject | Out-Null
Copy-Item -LiteralPath $fixture -Destination (Join-Path $defaultProject 'build.sig')
Copy-Item -LiteralPath $fixture -Destination (Join-Path $customProject 'project.sig')

$oldZigLibDir = $env:ZIG_LIB_DIR
$env:ZIG_LIB_DIR = $libPath
try {
    Push-Location $defaultProject
    try {
        $help = & $sigPath build --help `
            --cache-dir (Join-Path $proofRoot 'default-cache') `
            --global-cache-dir (Join-Path $proofRoot 'global-cache')
        if ($LASTEXITCODE -ne 0) { throw 'native build help probe failed' }
        $helpText = $help -join "`n"
        if ($helpText -notmatch '(?m)^Native build file:.*build\.sig$') { throw 'native build file was not selected' }
        if ($helpText -notmatch '(?m)^  native-release-proof') { throw 'native proof step was not registered' }
        if (Test-Path -LiteralPath 'build.zig') { throw 'native fixture unexpectedly contains build.zig' }
        if (Test-Path -LiteralPath 'native-sig-build.proof') { throw 'proof marker existed before step execution' }
        & $sigPath build native-release-proof `
            --cache-dir (Join-Path $proofRoot 'default-cache') `
            --global-cache-dir (Join-Path $proofRoot 'global-cache')
        if ($LASTEXITCODE -ne 0) { throw 'native proof step failed' }
        if ((Get-Content -Raw 'native-sig-build.proof').Trim() -ne 'native build.sig executed') {
            throw 'native proof marker contents differ'
        }
    }
    finally {
        Pop-Location
    }

    Push-Location $customProject
    try {
        $help = & $sigPath build --build-file project.sig --help `
            --cache-dir (Join-Path $proofRoot 'custom-cache') `
            --global-cache-dir (Join-Path $proofRoot 'global-cache')
        if ($LASTEXITCODE -ne 0) { throw 'custom .sig build-file probe failed' }
        $helpText = $help -join "`n"
        if ($helpText -notmatch '(?m)^Native build file:.*project\.sig$') { throw 'custom .sig build file was not selected' }
        if ($helpText -notmatch '(?m)^  native-release-proof') { throw 'custom build proof step was not registered' }
        if (Test-Path -LiteralPath 'build.sig') { throw 'custom fixture unexpectedly contains build.sig' }
        if (Test-Path -LiteralPath 'build.zig') { throw 'custom fixture unexpectedly contains build.zig' }
    }
    finally {
        Pop-Location
    }
}
finally {
    $env:ZIG_LIB_DIR = $oldZigLibDir
}

Write-Host "native build.sig package proof passed: $sigPath"
