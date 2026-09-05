[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CompilerRoot,
    [Parameter(Mandatory)][string]$ZpmBinary,
    [Parameter(Mandatory)][string]$StudioBinary,
    [Parameter(Mandatory)][string]$StudioToolsRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$BundleName = 'sig-sdk-0.5.2-dev-windows-x64'
)
$ErrorActionPreference = 'Stop'
if ($BundleName -notmatch '^[a-zA-Z0-9.-]+$') { throw 'Invalid bundle name' }
$compiler = (Resolve-Path -LiteralPath $CompilerRoot).Path
$zpm = (Resolve-Path -LiteralPath $ZpmBinary).Path
$studio = (Resolve-Path -LiteralPath $StudioBinary).Path
$studioTools = (Resolve-Path -LiteralPath $StudioToolsRoot).Path
foreach ($entry in @('scripts/project.ps1','templates/android/main.sig','templates/android/NativeSmoke.java','templates/android/plan.txt','templates/binary/main.sig','templates/site/main.sig','packages/sig-ui-0.1.0.zip','packages/sig-ui-0.1.0.json')) {
    if (!(Test-Path -LiteralPath (Join-Path $studioTools $entry) -PathType Leaf)) { throw "Incomplete Studio project tools: $entry" }
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
$bundle = Join-Path $output $BundleName
if (Test-Path -LiteralPath $bundle) { throw 'Choose a fresh bundle name; packaging never overwrites a previous SDK' }
foreach ($entry in @('bin/sig.exe','lib/std/std.sig','tools/sig_build/main.sig','tools/sig_build/build_host.sig')) {
    if (-not (Test-Path -LiteralPath (Join-Path $compiler $entry))) { throw "Incomplete compiler: $entry" }
}
New-Item -ItemType Directory -Path $output -Force | Out-Null
New-Item -ItemType Directory -Path $bundle | Out-Null
& robocopy $compiler $bundle /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Compiler bundle copy failed' }
Copy-Item -LiteralPath $zpm -Destination (Join-Path $bundle 'bin/zpm.exe')
Copy-Item -LiteralPath $studio -Destination (Join-Path $bundle 'bin/sig-studio.exe')
$studioDestination = Join-Path $bundle 'tools/sig-studio'
New-Item -ItemType Directory -Path (Join-Path $studioDestination 'scripts') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $studioTools 'scripts/project.ps1') -Destination (Join-Path $studioDestination 'scripts/project.ps1')
foreach ($directory in @('templates','packages')) { Copy-Item -LiteralPath (Join-Path $studioTools $directory) -Destination $studioDestination -Recurse }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'setup-sig/install-sdk.ps1') -Destination (Join-Path $bundle 'install.ps1')
$versions = @{}
foreach ($tool in @('sig','zpm')) {
    $argument = if ($tool -eq 'sig') { 'version' } else { '--version' }
    $versions[$tool] = (& (Join-Path $bundle "bin/$tool.exe") $argument | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Packaged $tool does not run" }
}
$files = @('bin/sig.exe','bin/zpm.exe','bin/sig-studio.exe','lib/sig/os.sig','lib/sig/process.sig','tools/sig_build/main.sig','tools/sig_build/build_host.sig','tools/sig_build/cli.sig')
if (Test-Path -LiteralPath (Join-Path $bundle 'lib/sig/application.sig')) {
    $files += @('lib/sig/application.sig','lib/sig/sig.sig')
    foreach ($appFile in Get-ChildItem -LiteralPath (Join-Path $bundle 'lib/sig/app') -File -Filter '*.sig') { $files += 'lib/sig/app/' + $appFile.Name }
}
$hashes = @{}
foreach ($file in Get-ChildItem -LiteralPath $studioDestination -Recurse -File) { $files += $file.FullName.Substring($bundle.Length+1).Replace('\','/') }
foreach ($entry in $files) { $hashes[$entry] = (Get-FileHash -LiteralPath (Join-Path $bundle $entry) -Algorithm SHA256).Hash.ToLowerInvariant() }
@{ schema = 1; name = $BundleName; channel = 'development'; versions = $versions; sha256 = $hashes; created_at = [DateTime]::UtcNow.ToString('o'); note = 'Development SDK: Sig 0.5.2 binary with the locally tested runtime/build-runner fixes, bundled ZPM and native Sig Studio preview. Not a signed stable release.' } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $bundle 'sdk-manifest.json') -Encoding utf8
@'
Sig SDK — development build

Includes the compiler, its matched library/build runner, prebuilt ZPM, and native Sig Studio.
No Node.js/npm runtime and no end-user compilation step are required.

Extract this complete directory. Run install.ps1 to install it for your Windows account,
or add its bin directory to PATH to use it as a portable SDK.

  sig version
  zpm --version
  zpm init --template cli-app --name hello
  cd hello
  zpm build
  zpm run -- "hello world"
  zpm test
  zpm build --release

The application SDK includes caller-buffer collections, type-derived JSON output,
field validation, and a real local HTTP starter:

  zpm init --template web-server --name service
  cd service
  zpm build
  zpm test
  zpm run

Open http://127.0.0.1:8080/health or /profile. This is a sequential local service;
production TLS, deadlines, authentication, database and job adapters are pending.
The current compiler accepts allocator calls in .sig files. The application APIs
use bounded storage, but compiler-level allocator rejection remains a release gate.

Launch bin/sig-studio.exe. New creates a project; Open selects an existing .sig file.
Code supports native editing, save, build, run, test and Install app / Deploy site.
Plan > Android example creates a real Sig UI project. Build plan verifies the pinned
c1aafbb source, tests Sig and JNI, compiles native libraries and verifies a debug APK.
The APK remains ready when no device is attached. Android builds additionally need
JDK 17 and Android SDK 36 / Build Tools 35.0.0 (not bundled). Gradle 8.11.1 uses the
included wrapper. The first build needs internet for Android dependencies.

Studio's Windows PowerShell adapter is in tools/sig-studio/scripts/project.ps1.
It can also create static site and standalone Windows binary projects. Site deployment
uses the Vercel CLI after one-time login/link, with preview as the default environment.
Binary installation uses a versioned per-user directory and Start Menu shortcut.
Plan supports provider account login through locally installed Codex/Claude CLIs.

This is a Windows development preview. The registry's native publish/install integration
and autonomous bottom-up framework execution are still under development. Do not treat
an AI-generated plan as a built, tested, or published framework.
'@ | Set-Content -LiteralPath (Join-Path $bundle 'README.txt') -Encoding utf8
$archive = "$bundle.zip"
& tar.exe -a -cf $archive -C $output $BundleName
if ($LASTEXITCODE -ne 0) { throw 'Archive creation failed' }
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $BundleName.zip" | Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
Write-Output $archive
Write-Output "SHA-256: $hash"
