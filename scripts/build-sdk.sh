#!/usr/bin/env bash
# Builds and installs the patched ReXGlue SDK for linux-arm64 with the Vulkan
# backend: the runtime (librexruntime.so), the GPU plugin
# (librexgpu-xenos.so) and the rexglue recompiler. Natively on aarch64, or
# cross-compiled on x86-64.
#
#   scripts/build-sdk.sh SDK TOOLCHAIN [INSTALL]
#
# SDK        a tree made by prepare.sh
# TOOLCHAIN  a folder made by fetch-toolchain.sh
# INSTALL    install prefix (default SDK/out/install/linux-arm64)
#
# On x86-64 the recompiler is run under qemu-aarch64 when it is installed.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$(cd "$1" && pwd)"
export SR_ARM64_TOOLCHAIN="$(cd "$2" && pwd)"
install="${3:-$sdk/out/install/linux-arm64}"
jobs="${JOBS:-$(nproc)}"
llvm="$SR_ARM64_TOOLCHAIN/llvm/bin"
export PATH="$SR_ARM64_TOOLCHAIN/bin:$PATH"

cmake -S "$sdk" --preset linux-arm64 \
    "-DCMAKE_TOOLCHAIN_FILE=$repo/cmake/toolchains/linux-arm64.cmake" \
    "-DCMAKE_C_COMPILER=$llvm/clang" "-DCMAKE_CXX_COMPILER=$llvm/clang++" \
    "-DCMAKE_INSTALL_PREFIX=$install" \
    -DREXGLUE_USE_VULKAN=ON -DREXGLUE_ENABLE_TRACY=OFF -DSDL_HIDAPI_LIBUSB=OFF
cmake --build "$sdk/out/build/linux-arm64" --config Release --target install --parallel "$jobs"

for f in "$install/bin/rexglue" "$install"/lib/librexruntime.so "$install"/lib/librexgpu-xenos.so; do
    if [ ! -e "$f" ]; then
        echo "error: $f was not built" >&2
        exit 1
    fi
    # ELF machine 183 (0xb7): AArch64.
    [ "$(od -An -tx1 -j18 -N2 "$f" | tr -d ' \n')" = b700 ] || { echo "error: $f is not aarch64" >&2; exit 1; }
    echo "OK $f (aarch64)"
done

run=()
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) if command -v qemu-aarch64-static >/dev/null; then
           run=(qemu-aarch64-static -L "$SR_ARM64_TOOLCHAIN/sysroot")
       elif command -v qemu-aarch64 >/dev/null; then
           run=(qemu-aarch64 -L "$SR_ARM64_TOOLCHAIN/sysroot")
       else
           echo "qemu-aarch64 not installed: not running the recompiler"
           exit 0
       fi ;;
esac
LD_LIBRARY_PATH="$install/lib" "${run[@]}" "$install/bin/rexglue" --version
