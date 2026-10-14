#!/usr/bin/env bash
# Builds tests/safety_net_test.cpp against Saints Reborn's AArch64 guest
# memory safety net and the installed SDK, and runs it: natively on aarch64,
# under qemu-aarch64 elsewhere.
#
#   scripts/test-safety-net.sh SAINTS_REBORN SDK_INSTALL TOOLCHAIN
#
# SAINTS_REBORN  Saints Reborn with patches/game applied
# SDK_INSTALL    the SDK installed by build-sdk.sh (out/install/linux-arm64)
# TOOLCHAIN      fetch-toolchain.sh's folder
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
sr="$(cd "$1" && pwd)"
sdk="$(cd "$2" && pwd)"
tc="$(cd "$3" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

linker=()
if [ -e "$tc/bin/ld.lld" ]; then
    linker=(--ld-path="$tc/bin/ld.lld")
fi
"$tc/llvm/bin/clang++" --target=aarch64-linux-gnu --sysroot="$tc/sysroot" -march=armv8.2-a \
    -std=c++23 -O2 -fuse-ld=lld "${linker[@]}" -static-libstdc++ \
    -I "$sr/project/src" -I "$sdk/include" \
    "$repo/tests/safety_net_test.cpp" "$sr/project/src/guest_safety_net_posix.cpp" \
    -L "$sdk/lib" -lrexruntime -Wl,-rpath,"$sdk/lib" -pthread \
    -o "$out/safety_net_test"

if [ "$(uname -m)" = aarch64 ]; then
    "$out/safety_net_test"
else
    qemu="$(command -v qemu-aarch64 || command -v qemu-aarch64-static)"
    # qemu's default CPU has SVE, so this also checks that skipped vector
    # loads reach the SVE part of the signal frame (patches/sdk/0004).
    QEMU_LD_PREFIX="$tc/sysroot" "$qemu" "$out/safety_net_test"
fi
