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

mkdir build-debug
cd build-debug

cmake .. \
  -DCMAKE_INSTALL_PREFIX="stage3-debug" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Debug \
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

stage3-debug/bin/Sig build test docs \
  --maxrss ${ZSF_MAX_RSS:-0} \
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

stage3-debug/bin/Sig build \
  --prefix stage4-debug \
  -Denable-llvm \
  -Dno-lib \
  -Dtarget=$TARGET \
  -Duse-Sig-libcxx \
  -Dversion-string="$(stage3-debug/bin/Sig version)"

stage4-debug/bin/Sig test ../test/behavior.sig
