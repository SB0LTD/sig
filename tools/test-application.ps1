[CmdletBinding()]
param([Parameter(Mandatory)][string]$Compiler, [switch]$RequireAllocatorRejection)
$ErrorActionPreference = 'Stop'
$compilerExe = (Resolve-Path -LiteralPath $Compiler).Path
$repo = Split-Path -Parent $PSScriptRoot
$work = Join-Path $repo '.sig-cache/application-check'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$application = Join-Path $repo 'lib/sig/application.sig'
& $compilerExe test $application
if ($LASTEXITCODE -ne 0) { throw 'Application library tests failed' }
& $compilerExe test $application -target x86_64-linux -fno-emit-bin
if ($LASTEXITCODE -ne 0) { throw 'Linux compile compatibility failed' }

foreach ($case in @(
    @{File='invalid_schema.sig'; Expected='unknown schema field: naem'},
    @{File='custom_hook.sig'; Expected='excludes custom jsonStringify hooks'}
)) {
    $source = Join-Path $repo ('test/application/'+$case.File)
    $diagnostic = & $compilerExe test --dep app "-Mroot=$source" "-Mapp=$application" -fno-emit-bin 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or -not $diagnostic.Contains($case.Expected)) { throw "Compile-time contract failed: $($case.File)" }
}

$serverSource = Join-Path $repo 'test/application/server.sig'
$serverExe = Join-Path $work 'application-server.exe'
& $compilerExe build-exe --dep app "-Mroot=$serverSource" "-Mapp=$application" "-femit-bin=$serverExe"
if ($LASTEXITCODE -ne 0) { throw 'HTTP adapter compilation failed' }
$appProcess = Start-Process -FilePath $serverExe -WindowStyle Hidden -PassThru
$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(3)
try {
    foreach ($case in @(
        @{Method='GET'; Path='/health'; Status=200},
        @{Method='HEAD'; Path='/health'; Status=200},
        @{Method='GET'; Path='/missing'; Status=404},
        @{Method='POST'; Path='/health'; Status=405},
        @{Method='GET'; Path='/fail'; Status=500}
    )) {
        $response = $null
        for ($attempt=0; $attempt -lt 60; $attempt++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($case.Method), 'http://127.0.0.1:18173'+$case.Path)
            try { $response = $client.SendAsync($request).GetAwaiter().GetResult(); break }
            catch { if ($appProcess.HasExited) { throw 'Test server exited before serving requests' }; Start-Sleep -Milliseconds 50 }
            finally { $request.Dispose() }
        }
        if ($null -eq $response -or [int]$response.StatusCode -ne $case.Status) { throw "HTTP check failed: $($case.Method) $($case.Path)" }
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($case.Method -eq 'HEAD' -and $body.Length -ne 0) { throw 'HEAD returned a body' }
        if ($case.Method -eq 'GET' -and $case.Path -eq '/health' -and ($body | ConvertFrom-Json).status -ne 'ok') { throw 'Invalid health JSON' }
        $response.Dispose()
    }
    if (-not $appProcess.WaitForExit(5000) -or $appProcess.ExitCode -ne 0) { throw 'Bounded server did not exit cleanly' }
} finally {
    $client.Dispose()
    if (-not $appProcess.HasExited) { $appProcess.Kill(); $appProcess.WaitForExit() }
    $appProcess.Dispose()
}

$probe = Join-Path $repo 'test/application/allocator_boundary.sig'
$allocatorDiagnostic = & $compilerExe build-exe $probe -fno-emit-bin 2>&1 | Out-String
$allocatorRejected = $LASTEXITCODE -ne 0 -and $allocatorDiagnostic -match '(?i)(strict|forbid|prohibit|disallow|not allowed).*allocat|allocat.*(strict|forbid|prohibit|disallow|not allowed)'
@{ library_tests='passed'; linux_compile='passed'; negative_api_checks=2; http_checks=5; allocator_rejected=$allocatorRejected } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $work 'compatibility.json')
Write-Output 'PASS: library tests, Linux compile, schema/hook rejection and five real HTTP responses.'
Write-Output "Compiler allocator rejection: $allocatorRejected (separate from the caller-buffer API contract)."
if ($RequireAllocatorRejection -and -not $allocatorRejected) { throw 'Production gate: this SDK does not reject the allocating .sig probe' }
