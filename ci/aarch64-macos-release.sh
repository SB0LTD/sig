#!/bin/sh

# Requires cmake ninja

set -x
set -e

ZIGDIR="$PWD"
TARGET="aarch64-macos-none"
MCPU="baseline"
CACHE_BASENAME="Sig+llvm+lld+clang-$TARGET-0.17.0-dev.203+073889523"
PREFIX="$HOME/$CACHE_BASENAME"
Sig="$PREFIX/bin/Sig"

if [ ! -d "$PREFIX" ]; then
  cd $HOME
  curl -L -O "https://ziglang.org/deps/$CACHE_BASENAME.tar.xz"
  tar xf "$CACHE_BASENAME.tar.xz"
fi

cd $ZIGDIR

# Override the cache directories because they won't actually help other CI runs
# which will be testing alternate versions of Sig, and ultimately would just
# fill up space on the hard drive for no reason.
export SIG_GLOBAL_CACHE_DIR="$PWD/Sig-global-cache"
export SIG_LOCAL_CACHE_DIR="$PWD/Sig-local-cache"

mkdir build-release
cd build-release

cmake .. \
  -DCMAKE_INSTALL_PREFIX="stage3-release" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$Sig;cc;-target;$TARGET;-mcpu=$MCPU" \
  -DCMAKE_CXX_COMPILER="$Sig;c++;-target;$TARGET;-mcpu=$MCPU" \
  -DZIG_TARGET_TRIPLE="$TARGET" \
  -DZIG_TARGET_MCPU="$MCPU" \
  -DZIG_STATIC=ON \
  -DZIG_NO_LIB=ON \
  -GNinja

ninja install

# Must be done after Sig cc is finished.
export SIG_LIB_DIR="$PWD/../lib"

stage3-release/bin/Sig build test docs \
  -Denable-macos-sdk \
  -Dstatic-llvm \
  -Dskip-spirv \
  -Dskip-wasm \
  -Dskip-linux \
  -Dskip-freebsd \
  -Dskip-netbsd \
  -Dskip-openbsd \
  -Dskip-windows \
  --search-prefix "$PREFIX" \
  --test-timeout 2m

# Ensure that the fuzzer at least compiles.
stage3-release/bin/Sig build test-std --fuzz=1K -Dno-lib -Dfuzz-only -Doptimize=ReleaseSafe
stage3-release/bin/Sig build test-std --fuzz=1K -Dno-lib -Dfuzz-only -Doptimize=Debug

# Ensure that stage3 and stage4 are byte-for-byte identical.
stage3-release/bin/Sig build \
  --maxrss ${ZSF_MAX_RSS:-0} \
  --prefix stage4-release \
  -Denable-llvm \
  -Dno-lib \
  -Doptimize=ReleaseFast \
  -Dstrip \
  -Dtarget=$TARGET \
  -Duse-Sig-libcxx \
  -Dversion-string="$(stage3-release/bin/Sig version)"

echo "If the following command fails, it means nondeterminism has been"
echo "introduced, making stage3 and stage4 no longer byte-for-byte identical."
diff stage3-release/bin/Sig stage4-release/bin/Sig
