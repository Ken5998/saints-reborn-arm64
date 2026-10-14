#!/usr/bin/env bash
# Builds Saints Reborn for linux-arm64 (the saintsrow program and glyphgen)
# against the SDK that build-sdk.sh installed: natively on aarch64, or
# cross-compiled on x86-64.
#
#   scripts/build-game.sh SAINTS_REBORN SDK_INSTALL TOOLCHAIN GENERATED [BUILD]
#
# SAINTS_REBORN  Saints Reborn made by prepare.sh (patches/game applied)
# SDK_INSTALL    build-sdk.sh's install prefix (SDK/out/install/linux-arm64)
# TOOLCHAIN      fetch-toolchain.sh's folder
# GENERATED      the code `rexglue codegen` made from the game
#                (SAINTS_REBORN/build/generated), or placeholder-codegen.py's
#                to check the build without the game
# BUILD          build folder (default SAINTS_REBORN/build/linux-arm64)
#
# Parallel jobs: SR_JOBS, else one per logical CPU but at most one per 2 GB of
# memory, as Saints Reborn's own setup does (the recompiled files are huge).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
sr="$(cd "$1" && pwd)"
sdk="$(cd "$2" && pwd)"
export SR_ARM64_TOOLCHAIN="$(cd "$3" && pwd)"
generated="$(cd "$4" && pwd)"
build="${5:-$sr/build/linux-arm64}"
llvm="$SR_ARM64_TOOLCHAIN/llvm/bin"
export PATH="$SR_ARM64_TOOLCHAIN/bin:$PATH"

if [ -n "${SR_JOBS:-}" ]; then
    jobs="$SR_JOBS"
else
    mem_gb=$(( $(sed -n 's/^MemTotal: *\([0-9]*\) kB/\1/p' /proc/meminfo) / 1048576 ))
    jobs=$(( mem_gb / 2 ))
    [ "$jobs" -le "$(nproc)" ] || jobs="$(nproc)"
    [ "$jobs" -ge 1 ] || jobs=1
fi
echo "Building with $jobs parallel jobs ($(nproc) CPU threads)"

# find_package(rexglue) looks only inside the sysroot and the SDK
# (CMAKE_FIND_ROOT_PATH); "/" makes it search the SDK's lib/cmake there.
cmake -S "$sr/project" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_TOOLCHAIN_FILE=$repo/cmake/toolchains/linux-arm64.cmake" \
    "-DCMAKE_C_COMPILER=$llvm/clang" "-DCMAKE_CXX_COMPILER=$llvm/clang++" \
    "-DCMAKE_FIND_ROOT_PATH=$sdk" -DCMAKE_PREFIX_PATH=/ \
    "-DSR_GENERATED_DIR=$generated"
cmake --build "$build" --target saintsrow glyphgen --parallel "$jobs"

for f in "$build/saintsrow" "$build/glyphgen"; do
    # ELF machine 183 (0xb7): AArch64.
    [ "$(od -An -tx1 -j18 -N2 "$f" | tr -d ' \n')" = b700 ] || { echo "error: $f is not aarch64" >&2; exit 1; }
    echo "OK $f (aarch64)"
done
