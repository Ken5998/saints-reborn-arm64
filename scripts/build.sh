#!/usr/bin/env bash
# Builds Saints Reborn for linux-arm64 from your own Saints Row disc image,
# start to finish: the toolchain, the patched ReXGlue SDK, the game files
# from the ISO, the recompiled code, the game, and a ready folder to play
# from, added to Steam with its artwork. Made for the handheld itself
# (ArmadaOS on the Retroid Pocket 6, or any aarch64 Linux); it also runs on
# x86-64 Linux with qemu-user installed, and the result is then copied to the
# handheld. SR_ADD_TO_STEAM=0 leaves Steam alone.
#
#   scripts/build.sh ISO [DIR]
#
# ISO  your Saints Row (Xbox 360) disc image
# DIR  where everything goes (default ~/.local/share/SaintsReborn-arm64);
#      about 40 GB free is needed while building
#
# Run it again after updating this repository: finished steps are skipped
# when nothing they depend on changed, and the game build recompiles only the
# files a change touches. The game is DIR/SaintsReborn/dist; nothing made
# here may be published (it is built from your copy of the game).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] && [ -f "$1" ] || { echo "usage: $0 ISO [DIR]" >&2; exit 2; }
iso="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
dir="${2:-$HOME/.local/share/SaintsReborn-arm64}"
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"
tc="$dir/toolchain"
sr="$dir/SaintsReborn"
sdk_src="$dir/rexglue-sdk"
sdk="$sdk_src/out/install/linux-arm64"
dist="$sr/dist"
game="$dist/game"
stamps="$dir/.stamps"
mkdir -p "$stamps"

step() { printf '\n==> %s\n' "$*"; }
key() { cat "$@" | sha256sum | cut -d' ' -f1; }  # key FILE...: a hash of their contents
done_with() { [ -f "$stamps/$1" ] && [ "$(cat "$stamps/$1")" = "$2" ]; }
mark() { echo "$2" > "$stamps/$1"; }

# aarch64 programs made here run natively on the handheld, under qemu elsewhere.
run=()
case "$(uname -m)" in
    aarch64|arm64) ;;
    x86_64|amd64)
        qemu="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
        [ -n "$qemu" ] || { echo "error: on x86-64 this needs qemu-aarch64 (qemu-user)" >&2; exit 1; }
        run=("$qemu" -L "$tc/sysroot") ;;
    *) echo "error: build on aarch64 or x86-64 Linux" >&2; exit 1 ;;
esac

step "Toolchain"
"$repo/scripts/fetch-toolchain.sh" "$tc"
export PATH="$tc/bin:$PATH"

prepare_key="$(key "$repo/upstream.json" "$repo/scripts/prepare.sh" \
    "$repo"/patches/sdk/*.patch "$repo"/patches/game/*.patch)"
if done_with prepare "$prepare_key"; then
    echo "Saints Reborn and the SDK already prepared - skipping."
else
    step "Saints Reborn and the ReXGlue SDK"
    "$repo/scripts/prepare.sh" "$dir"
    mark prepare "$prepare_key"
fi

# The SDK, and the code recompiled with it, depend on the SDK patches, not on
# the game's.
sdk_key="$(key "$repo/upstream.json" "$repo/scripts/prepare.sh" "$repo"/patches/sdk/*.patch \
    "$repo/toolchain.json" "$repo/scripts/build-sdk.sh" "$repo/cmake/toolchains/linux-arm64.cmake")"
if done_with sdk "$sdk_key"; then
    echo "ReXGlue SDK already built - skipping."
else
    step "Building the ReXGlue SDK (this takes a while)"
    "$repo/scripts/build-sdk.sh" "$sdk_src" "$tc" "$sdk"
    mark sdk "$sdk_key"
fi

clang=("$tc/llvm/bin/clang++" --target=aarch64-linux-gnu "--sysroot=$tc/sysroot"
       -fuse-ld=lld -static-libstdc++)
[ ! -e "$tc/bin/ld.lld" ] || clang+=("--ld-path=$tc/bin/ld.lld")
if [ -f "$game/default.xex" ] && done_with extract "$iso"; then
    echo "Game files already extracted to $game - skipping."
else
    step "Extracting the game from $iso (about 6 GB)"
    mkdir -p "$sr/build"
    "${clang[@]}" -std=c++17 -O2 -o "$sr/build/xiso_extract" "$sr/tools/xiso_extract/xiso_extract.cpp"
    rm -rf "$game"
    mkdir -p "$dist"
    "${run[@]}" "$sr/build/xiso_extract" "$iso" "$game" \
        --skip-name '$SystemUpdate' --skip-name layer1filler.bin --skip-name layer2filler.bin
    [ -f "$game/default.xex" ] || {
        echo "error: the disc image has no default.xex - is it an Xbox 360 game disc?" >&2; exit 1; }
    mark extract "$iso"
fi
# Saints Reborn's hooks are made for one build of the game.
xex_sha1="$(sha1sum "$game/default.xex" | cut -d' ' -f1 | tr a-f A-F)"
if [ "$xex_sha1" != C2646093FF3926141FCF4FD630E876873D1CAECE ]; then
    echo "WARNING: your default.xex (SHA-1 $xex_sha1) is not the version Saints Reborn was" \
         "made for. The build may fail or the game may not run correctly."
fi

codegen_key="$sdk_key $xex_sha1"
if done_with codegen "$codegen_key" && [ -f "$sr/build/generated/sources.cmake" ]; then
    echo "Recompiled code already generated - skipping."
else
    step "Recompiling default.xex (PowerPC to C++)"
    # Files that come out the same are left as they are (and not recompiled).
    (cd "$sr" && LD_LIBRARY_PATH="$sdk/lib" "${run[@]}" "$sdk/bin/rexglue" \
        codegen config/saintsrow_manifest.toml --ignore-stamp)
    mark codegen "$codegen_key"
fi

step "Building Saints Reborn (compiles ~34,000 functions; an hour or more on a handheld)"
"$repo/scripts/build-game.sh" "$sr" "$sdk" "$tc" "$sr/build/generated" "$sr/build/linux-arm64"

step "Copying the game to $dist"
build="$sr/build/linux-arm64"
cp -f "$build/saintsrow" "$sdk/lib/librexruntime.so" "$sdk/lib/librexgpu-xenos.so" "$dist/"
# Built-in parts and mods, without the co-op and Zombies DLLs and the native
# mods, which are Windows only.
copy_part() {  # copy_part FROM TO: a mod folder without its sources
    mkdir -p "$2"
    (cd "$1" && find . -type f ! -name '*.png' ! -name '*.py' ! -name '*.c' ! -name '*.cpp' \
        ! -name '*.h' ! -name '*.ps1' ! -name '*.bak*' ! -name join_ip.txt -print0) |
        (cd "$1" && xargs -0r cp --parents -f -t "$2")
}
for part in "$sr"/core/*/; do
    name="$(basename "$part")"
    case "$name" in WhompaysCoop|Zombies) continue ;; esac
    copy_part "$part" "$dist/core/$name"
done
for mod in "$sr"/modding/examples/*/ "$sr"/modding/mods/*/; do
    name="$(basename "$mod")"
    case "$name" in ExampleNative|WhompaysTrainer) continue ;; esac
    copy_part "$mod" "$dist/mods/$name"
done

# Keyboard/mouse button pictures, made from your own game files.
step "Making the keyboard/mouse button pictures"
"${run[@]}" "$build/glyphgen" "$game/packfiles" "$sr/tools/glyphgen/art.txt" "$dist/kbm_ui.bin" ||
    echo "Warning: the keyboard/mouse button pictures could not be made; the game will show controller buttons."

# On a machine that builds for another one (x86-64), Steam is the other's.
steam=no
if [ "${SR_ADD_TO_STEAM:-1}" = 1 ] && [ ${#run[@]} -eq 0 ]; then
    step "Adding Saints Reborn to Steam"
    if "$repo/scripts/add-to-steam.sh" "$dir"; then
        steam=yes
    else
        echo "Warning: Saints Reborn was not added to Steam; scripts/add-to-steam.sh tries again."
    fi
fi

echo
echo "Done! Saints Reborn is in $dist."
if [ "$steam" = yes ]; then
    echo "Play it from Steam (\"Saints Reborn\" in the library): the handheld's controls reach it only from there."
else
    echo "Play it from Steam (scripts/add-to-steam.sh adds it) so the controls work,"
    echo "or run $dist/saintsrow from a terminal."
fi
