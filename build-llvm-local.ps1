#Requires -Version 7.3
# Build LLVM 22 locally on Windows with MSVC
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$llvmCommit = "a255c1ed36a1d06f79bd2633ba9f8d900153007c"
$artifactTag = "llvm-22.1.7-sig-0.3.0.r2"
$archive = "C:\llvm-22-x86_64-windows-native.tar.zst"

# Activate MSVC
$vsPath = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
Import-Module "$vsPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=amd64"
Write-Host "MSVC activated: $(cl 2>&1 | Select-Object -First 1)"

# Clone if needed
if (-not (Test-Path "C:\llvm-build-src")) {
    Write-Host "Cloning LLVM..."
    git clone --depth 1 --branch llvmorg-22.1.7 https://github.com/llvm/llvm-project.git C:\llvm-build-src
    if ($LASTEXITCODE -ne 0) { throw "LLVM clone failed" }
}
$actualCommit = (git -C C:\llvm-build-src rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "Unable to resolve LLVM source commit" }
if ($actualCommit -ne $llvmCommit) {
    throw "LLVM source mismatch: expected $llvmCommit, found $actualCommit"
}

# Configure
Write-Host "Configuring..."
cmake -S C:\llvm-build-src\llvm -B C:\llvm-build -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded `
    -DCMAKE_INSTALL_PREFIX="C:\llvm-22-built" `
    -DLLVM_ENABLE_PROJECTS="clang;lld" `
    -DLLVM_TARGETS_TO_BUILD="AArch64;AMDGPU;ARM;AVR;BPF;Hexagon;Lanai;LoongArch;Mips;MSP430;NVPTX;PowerPC;RISCV;Sparc;SPIRV;SystemZ;VE;WebAssembly;X86;XCore" `
    -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD="ARC;CSKY;M68k;Xtensa" `
    -DLLVM_ENABLE_TERMINFO=OFF `
    -DLLVM_ENABLE_LIBXML2=OFF `
    -DLLVM_ENABLE_ZLIB=OFF `
    -DLLVM_ENABLE_ZSTD=OFF `
    -DBUILD_SHARED_LIBS=OFF `
    -DLLVM_BUILD_LLVM_DYLIB=OFF `
    -DLLVM_BUILD_TOOLS=ON `
    -DCLANG_ENABLE_ARCMT=OFF `
    -DCLANG_ENABLE_STATIC_ANALYZER=ON `
    -DLLVM_ENABLE_BINDINGS=OFF `
    -DLLVM_ENABLE_OCAMLDOC=OFF `
    -DLLVM_INCLUDE_TESTS=OFF `
    -DLLVM_INCLUDE_EXAMPLES=OFF `
    -DLLVM_INCLUDE_BENCHMARKS=OFF `
    -DLLVM_INCLUDE_DOCS=OFF
if ($LASTEXITCODE -ne 0) { throw "LLVM configuration failed" }

# Build and install
Write-Host "Building..."
ninja -C C:\llvm-build install
if ($LASTEXITCODE -ne 0) { throw "LLVM build or install failed" }
$builtVersion = (& C:\llvm-22-built\bin\llvm-config.exe --version).Trim()
if ($LASTEXITCODE -ne 0 -or $builtVersion -ne "22.1.7") {
    throw "LLVM version probe failed: $builtVersion"
}

# Package
Write-Host "Packaging..."
tar -cf - -C C:\ llvm-22-built/ | zstd --force -19 -T0 -o $archive
if ($LASTEXITCODE -ne 0) { throw "LLVM archive creation failed" }
$hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($archive))" | Set-Content -Encoding ascii "$archive.sha256"

Write-Host "Done! Upload with:"
Write-Host "  gh release upload $artifactTag $archive $archive.sha256"
