[CmdletBinding()]
param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'SB0/Sig'), [switch]$NoPath)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sdk-manifest.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest.sha256.PSObject.Properties) {
    $actual = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "SDK integrity check failed: $($entry.Name)" }
}
$root = [IO.Path]::GetFullPath($Destination)
$target = Join-Path $root $manifest.name
if (Test-Path -LiteralPath $target) { throw "An installation already exists at $target. Choose another destination to keep rollback available." }
New-Item -ItemType Directory -Path $root -Force | Out-Null
$stage = Join-Path $root ('.install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
& robocopy $PSScriptRoot $stage /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Installation copy failed; no installation was activated' }
foreach ($entry in $manifest.sha256.PSObject.Properties) {
    if ((Get-FileHash -LiteralPath (Join-Path $stage $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value) { throw 'Copied SDK verification failed' }
}
$resolvedStage = [IO.Path]::GetFullPath($stage)
$resolvedTarget = [IO.Path]::GetFullPath($target)
if (-not $resolvedStage.StartsWith($root + [IO.Path]::DirectorySeparatorChar) -or -not $resolvedTarget.StartsWith($root + [IO.Path]::DirectorySeparatorChar)) { throw 'Invalid activation paths' }
Move-Item -LiteralPath $resolvedStage -Destination $resolvedTarget
$bin = Join-Path $target 'bin'
if (-not $NoPath) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($current -split ';' | Where-Object { $_ -and $_ -ne $bin })
    [Environment]::SetEnvironmentVariable('Path', (($bin) + ';' + ($entries -join ';')), 'User')
}
Write-Output "Installed Sig, ZPM and Sig Studio: $bin"
Write-Output 'Open a new terminal, then run zpm --version. Launch sig-studio to open the editor.'
