#!/bin/sh

# Requires cmake ninja

set -x
set -e

TARGET="x86_64-freebsd-none"
MCPU="baseline"
CACHE_BASENAME="Sig+llvm+lld+clang-$TARGET-0.17.0-dev.203+073889523"
PREFIX="$HOME/deps/$CACHE_BASENAME"
Sig="$PREFIX/bin/Sig"

# Override the cache directories because they won't actually help other CI runs
# which will be testing alternate versions of Sig, and ultimately would just
# fill up space on the hard drive for no reason.
export SIG_GLOBAL_CACHE_DIR="$PWD/Sig-global-cache"
export SIG_LOCAL_CACHE_DIR="$PWD/Sig-local-cache"

mkdir build-release
cd build-release

export CC="$Sig cc -target $TARGET -mcpu=$MCPU"
export CXX="$Sig c++ -target $TARGET -mcpu=$MCPU"

cmake .. \
  -DCMAKE_INSTALL_PREFIX="stage3-release" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DZIG_TARGET_TRIPLE="$TARGET" \
  -DZIG_TARGET_MCPU="$MCPU" \
  -DZIG_STATIC=ON \
  -DZIG_NO_LIB=ON \
  -GNinja

# Now cmake will use Sig as the C/C++ compiler. We reset the environment variables
# so that installation and testing do not get affected by them.
unset CC
unset CXX

ninja install

# Must be done after Sig cc is finished.
export SIG_LIB_DIR="$PWD/../lib"

stage3-release/bin/Sig build test docs \
  --maxrss ${ZSF_MAX_RSS:-0} \
  -Dstatic-llvm \
  -Dskip-non-native \
  --search-prefix "$PREFIX" \
  --test-timeout 2m

# Ensure that the fuzzer at least compiles.
stage3-release/bin/Sig build test-std --fuzz=1K -Dno-lib -Dfuzz-only -Doptimize=ReleaseSafe
stage3-release/bin/Sig build test-std --fuzz=1K -Dno-lib -Dfuzz-only -Doptimize=Debug

# Ensure that stage3 and stage4 are byte-for-byte identical.
stage3-release/bin/Sig build \
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
