# Build LLVM 22 locally on Windows with MSVC
$ErrorActionPreference = "Stop"

# Activate MSVC
$vsPath = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
Import-Module "$vsPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=amd64"
Write-Host "MSVC activated: $(cl 2>&1 | Select-Object -First 1)"

# Clone if needed
if (-not (Test-Path "C:\llvm-build-src")) {
    Write-Host "Cloning LLVM..."
    git clone --depth 1 --branch llvmorg-22.1.3 https://github.com/llvm/llvm-project.git C:\llvm-build-src
}

# Configure
Write-Host "Configuring..."
cmake -S C:\llvm-build-src\llvm -B C:\llvm-build -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_INSTALL_PREFIX="C:\llvm-22-built" `
    -DLLVM_ENABLE_PROJECTS="clang;lld" `
    -DLLVM_TARGETS_TO_BUILD="AArch64;AMDGPU;ARM;AVR;BPF;Hexagon;Lanai;LoongArch;Mips;MSP430;NVPTX;PowerPC;RISCV;Sparc;SystemZ;VE;WebAssembly;X86;XCore" `
    -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD="M68k;Xtensa;ARC;CSKY;SPIRV" `
    -DLLVM_ENABLE_TERMINFO=OFF `
    -DLLVM_ENABLE_LIBXML2=OFF `
    -DLLVM_ENABLE_ZLIB=OFF `
    -DLLVM_ENABLE_ZSTD=OFF `
    -DCLANG_ENABLE_ARCMT=OFF `
    -DCLANG_ENABLE_STATIC_ANALYZER=ON `
    -DLLVM_ENABLE_BINDINGS=OFF `
    -DLLVM_ENABLE_OCAMLDOC=OFF `
    -DLLVM_INCLUDE_TESTS=OFF `
    -DLLVM_INCLUDE_EXAMPLES=OFF `
    -DLLVM_INCLUDE_BENCHMARKS=OFF `
    -DLLVM_INCLUDE_DOCS=OFF

# Build and install
Write-Host "Building..."
ninja -C C:\llvm-build install

# Package
Write-Host "Packaging..."
tar -cJf C:\llvm-22-x86_64-windows.tar.xz -C C:\ llvm-22-built/

Write-Host "Done! Upload with:"
Write-Host "  gh release upload llvm-22 C:\llvm-22-x86_64-windows.tar.xz --clobber"
