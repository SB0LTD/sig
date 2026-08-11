# [sig] setup-sig — Windows setup script for the Sig compiler
param(
    [Parameter(Mandatory)][string]$Action,
    [string]$Version = '',
    [string]$Mirror = '',
    [string]$DownloadUrl = '',
    [string]$ToolDir = '',
    [string]$CacheHit = 'false',
    [string]$CacheSizeLimit = '2048'
)

$ErrorActionPreference = 'Stop'
$GithubRepository = 'SB0LTD/sig'
$GithubReleaseBase = "https://github.com/$GithubRepository/releases"
$GithubApiBase = "https://api.github.com/repos/$GithubRepository"

# --- Helpers ---

function Get-PlatformTriple {
    $arch = if ([System.Environment]::Is64BitOperatingSystem) { 'x86_64' } else {
        Write-Output "::error::Unsupported architecture: 32-bit Windows"
        exit 1
    }
    return "${arch}-windows"
}

function Resolve-VersionFromManifest {
    $manifest = $null
    if (Test-Path 'build.sig.zon') { $manifest = 'build.sig.zon' }
    elseif (Test-Path 'build.zig.zon') { $manifest = 'build.zig.zon' }

    if ($manifest) {
        $content = Get-Content $manifest -Raw
        if ($content -match '\.minimum_sig_version\s*=\s*"([^"]+)"') {
            return $Matches[1]
        }
    }
    return ''
}

function Resolve-LatestVersion {
    try {
        $response = Invoke-RestMethod -Uri "$GithubApiBase/releases/latest" `
            -Headers @{ 'User-Agent' = 'setup-sig' } -ErrorAction Stop
        $tag = $response.tag_name -replace '^sig-', ''
        return $tag
    } catch {
        Write-Output "::warning::Could not query latest release from GitHub API"
        return ''
    }
}

function Resolve-RequestedVersion {
    param([string]$Requested)

    $requestedVersion = $Requested -replace '^sig-', ''
    if (-not $requestedVersion -or $requestedVersion -eq 'latest') {
        return Resolve-LatestVersion
    }
    if ($requestedVersion -eq 'master') {
        throw "'master' is not an immutable Sig release; use 'latest' or a version"
    }
    if ($requestedVersion -match '^\d+\.\d+\.\d+$') {
        $releases = Invoke-RestMethod -Uri "$GithubApiBase/releases?per_page=100" `
            -Headers @{ 'User-Agent' = 'setup-sig' }
        $prefix = "sig-${requestedVersion}-zig"
        $release = $releases | Where-Object {
            -not $_.draft -and -not $_.prerelease -and $_.tag_name.StartsWith($prefix)
        } | Select-Object -First 1
        if (-not $release) { throw "No stable Sig ${requestedVersion} release was found" }
        return ($release.tag_name -replace '^sig-', '')
    }
    try {
        $null = Invoke-RestMethod -Uri "$GithubApiBase/releases/tags/sig-${requestedVersion}" `
            -Headers @{ 'User-Agent' = 'setup-sig' } -ErrorAction Stop
    } catch {
        throw "No published Sig release has identity ${requestedVersion}"
    }
    return $requestedVersion
}

function Get-DownloadUrl {
    param([string]$Ver, [string]$Mir, [string]$Triple)
    $base = if ($Mir) { $Mir } else { "${GithubReleaseBase}/download/sig-${Ver}" }
    return "${base}/sig-${Ver}-${Triple}.zip"
}

function Get-ZigCacheDir {
    return Join-Path $env:LOCALAPPDATA 'zig'
}

# --- Actions ---

function Invoke-Resolve {
    $triple = Get-PlatformTriple
    $ver = $Version

    if (-not $ver) {
        $ver = Resolve-VersionFromManifest
    }
    $ver = Resolve-RequestedVersion -Requested $ver
    if (-not $ver) {
        Write-Output "::error::Could not resolve Sig version. Specify one explicitly."
        exit 1
    }

    $url = Get-DownloadUrl -Ver $ver -Mir $Mirror -Triple $triple

    "resolved-version=${ver}" | Out-File -Append -FilePath $env:GITHUB_OUTPUT -Encoding utf8
    "download-url=${url}" | Out-File -Append -FilePath $env:GITHUB_OUTPUT -Encoding utf8
    "platform-triple=${triple}" | Out-File -Append -FilePath $env:GITHUB_OUTPUT -Encoding utf8
    Write-Output "Resolved Sig version: ${ver} for ${triple}"
}

function Invoke-Install {
    if ($CacheHit -eq 'true' -and (Test-Path (Join-Path $ToolDir 'bin\sig.exe'))) {
        Write-Output "Sig ${Version} restored from cache"
        return
    }

    Write-Output "Downloading Sig ${Version} from ${DownloadUrl}"
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $zipFile = Join-Path $tmpDir 'sig.zip'

    Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipFile -UseBasicParsing

    $checksumsFile = Join-Path $tmpDir 'SHA256SUMS.txt'
    $checksumsName = $null
    foreach ($candidate in @('SHA256SUMS.txt', 'sha256sums.txt')) {
        try {
            Invoke-WebRequest -Uri ((Split-Path $DownloadUrl -Parent) + "/$candidate") `
                -OutFile $checksumsFile -UseBasicParsing -ErrorAction Stop
            $checksumsName = $candidate
            break
        } catch {
            # Try the legacy/current alternate aggregate name.
        }
    }
    if (-not $checksumsName) {
        Remove-Item -Recurse -Force -LiteralPath $tmpDir
        throw 'Release checksum manifest is unavailable'
    }
    $archiveName = Split-Path $DownloadUrl -Leaf
    $checksumLine = Get-Content $checksumsFile | Where-Object {
        $parts = $_ -split '\s+', 2
        $parts.Count -eq 2 -and $parts[1] -eq $archiveName
    } | Select-Object -First 1
    if (-not $checksumLine) {
        Remove-Item -Recurse -Force -LiteralPath $tmpDir
        throw "${archiveName} is absent from ${checksumsName}"
    }
    $expected = ($checksumLine -split '\s+')[0].ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        Remove-Item -Recurse -Force -LiteralPath $tmpDir
        throw "Invalid digest for ${archiveName} in ${checksumsName}"
    }
    $actual = (Get-FileHash -Path $zipFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        Remove-Item -Recurse -Force -LiteralPath $tmpDir
        throw "Checksum mismatch! Expected: ${expected}, Got: ${actual}"
    }
    Write-Output "Checksum verified via ${checksumsName}"

    # Extract
    if (-not (Test-Path $ToolDir)) {
        New-Item -ItemType Directory -Path $ToolDir -Force | Out-Null
    }
    Expand-Archive -Path $zipFile -DestinationPath $tmpDir -Force
    # Move contents (strip top-level directory if present)
    $extracted = Get-ChildItem -Path $tmpDir -Directory | Where-Object { $_.Name -ne 'sig.zip' } | Select-Object -First 1
    if ($extracted -and (Test-Path (Join-Path $extracted.FullName 'bin'))) {
        Copy-Item -Path (Join-Path $extracted.FullName '*') -Destination $ToolDir -Recurse -Force
    } else {
        Copy-Item -Path (Join-Path $tmpDir '*') -Destination $ToolDir -Recurse -Force -Exclude 'sig.zip','SHA256SUMS.txt'
    }
    Remove-Item -Recurse -Force $tmpDir

    Write-Output "Sig ${Version} installed to ${ToolDir}"
}

function Invoke-CacheLimit {
    $cacheDir = Get-ZigCacheDir
    if (-not (Test-Path $cacheDir)) { return }

    $sizeBytes = (Get-ChildItem -Path $cacheDir -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $sizeMib = [math]::Floor($sizeBytes / 1048576)
    $limitMib = [int]$CacheSizeLimit

    if ($sizeMib -gt $limitMib) {
        Write-Output "Zig cache (${sizeMib} MiB) exceeds limit (${limitMib} MiB) — clearing"
        Remove-Item -Recurse -Force $cacheDir
    } else {
        Write-Output "Zig cache size: ${sizeMib} MiB (limit: ${limitMib} MiB)"
    }
}

# --- Dispatch ---

switch ($Action) {
    'resolve'     { Invoke-Resolve }
    'install'     { Invoke-Install }
    'cache-limit' { Invoke-CacheLimit }
    default {
        Write-Output "::error::Unknown action: $Action"
        exit 1
    }
}
