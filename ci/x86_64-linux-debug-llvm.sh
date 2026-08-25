#!/bin/sh

# Requires cmake ninja-build

set -x
set -e

TARGET="x86_64-linux-musl"
MCPU="baseline"
CACHE_BASENAME="Sig+llvm+lld+clang-$TARGET-0.17.0-dev.203+073889523"
PREFIX="$HOME/deps/$CACHE_BASENAME"
Sig="$PREFIX/bin/Sig"

export PATH="$HOME/deps/wasmtime-v46.0.1-x86_64-linux:$HOME/deps/qemu-linux-x86_64-11.1.0/bin:$HOME/local/bin:$PATH"

# Override the cache directories because they won't actually help other CI runs
# which will be testing alternate versions of Sig, and ultimately would just
# fill up space on the hard drive for no reason.
export SIG_GLOBAL_CACHE_DIR="$PWD/Sig-global-cache"
export SIG_LOCAL_CACHE_DIR="$PWD/Sig-local-cache"

mkdir build-debug-llvm
cd build-debug-llvm

export CC="$Sig cc -target $TARGET -mcpu=$MCPU"
export CXX="$Sig c++ -target $TARGET -mcpu=$MCPU"

cmake .. \
  -DCMAKE_INSTALL_PREFIX="stage3-debug" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DZIG_TARGET_TRIPLE="$TARGET" \
  -DZIG_TARGET_MCPU="$MCPU" \
  -DZIG_STATIC=ON \
  -DZIG_NO_LIB=ON \
  -DZIG_EXTRA_BUILD_ARGS="-Duse-llvm=true" \
  -GNinja

# Now cmake will use Sig as the C/C++ compiler. We reset the environment variables
# so that installation and testing do not get affected by them.
unset CC
unset CXX

ninja install

# Must be done after Sig cc is finished.
export SIG_LIB_DIR="$PWD/../lib"

# simultaneously test building self-hosted without LLVM and with 32-bit arm
stage3-debug/bin/Sig build \
  -Dtarget=arm-linux-musleabihf \
  -Dno-lib

stage3-debug/bin/Sig build test docs \
  --maxrss ${ZSF_MAX_RSS:-0} \
  -Dlldb=$HOME/deps/lldb-Sig/Debug-7c1090fd46/bin/lldb \
  -Dlibc-test-path=$HOME/deps/libc-test-b95fe84 \
  -fqemu \
  --libc-runtimes $HOME/deps/glibc-2.43-musl-1.2.5 \
  -fwasmtime \
  -Dstatic-llvm \
  -Dskip-freebsd \
  -Dskip-netbsd \
  -Dskip-openbsd \
  -Dskip-windows \
  -Dskip-darwin \
  -Dtarget=native-native-musl \
  --search-prefix "$PREFIX" \
  -Denable-superhtml \
  --test-timeout 12m

stage3-debug/bin/Sig build \
  --prefix stage4-debug \
  -Duse-llvm \
  -Denable-llvm \
  -Dno-lib \
  -Dtarget=$TARGET \
  -Duse-Sig-libcxx \
  -Dversion-string="$(stage3-debug/bin/Sig version)"

stage4-debug/bin/Sig test ../test/behavior.sig
