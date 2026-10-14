#!/usr/bin/env bash
# Downloads the pinned toolchain into DEST: LLVM 20.1.8 for this machine
# (aarch64 or x86-64), the Ubuntu 24.04 arm64 sysroot that pinyon-shift-arm64
# publishes and, on aarch64, CMake and Ninja (ArmadaOS has neither; x86-64
# build machines use their own), all checked against toolchain.json. DEST is
# what cmake/toolchains/linux-arm64.cmake expects in SR_ARM64_TOOLCHAIN;
# DEST/bin goes first in PATH.
#
#   scripts/fetch-toolchain.sh DEST
#
# Needs only curl, tar, xz and python3, so it also runs on ArmadaOS.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
dest="$(mkdir -p "$1" && cd "$1" && pwd)"
arch="$(uname -m)"
case "$arch" in
    aarch64|arm64) arch=aarch64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *) echo "error: unsupported machine $arch" >&2; exit 1 ;;
esac

field() {  # field KEY... : a value from toolchain.json
    python3 -c 'import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2:]: v = v[k]
print(v)' "$repo/toolchain.json" "$@"
}

fetch() {  # fetch URL SHA256 FOLDER [TAR OPTIONS...]: unpack once into DEST/FOLDER
    local url="$1" sha="$2" folder="$3"
    shift 3
    if [ -f "$dest/$folder/.sha256" ] && [ "$(cat "$dest/$folder/.sha256")" = "$sha" ]; then
        return
    fi
    local archive="$dest/${url##*/}"
    echo "Downloading ${url##*/}"
    curl -fsSL --retry 4 -o "$archive" "$url"
    if [ "$(sha256sum "$archive" | cut -d' ' -f1 | tr a-f A-F)" != "$sha" ]; then
        echo "error: ${url##*/} does not match toolchain.json" >&2
        exit 1
    fi
    rm -rf "${dest:?}/$folder.tmp"
    mkdir -p "$dest/$folder.tmp"
    case "$archive" in
        *.zip) python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
                   "$archive" "$dest/$folder.tmp" ;;
        *) tar -xf "$archive" -C "$dest/$folder.tmp" "$@" ;;
    esac
    rm -f "$archive"
    echo "$sha" > "$dest/$folder.tmp/.sha256"
    rm -rf "${dest:?}/$folder"
    mv "$dest/$folder.tmp" "$dest/$folder"
}

fetch "$(field llvm "$arch" url)" "$(field llvm "$arch" sha256)" llvm --strip-components=1
fetch "$(field sysroot url)" "$(field sysroot sha256)" sysroot
mkdir -p "$dest/bin"
if [ "$arch" = aarch64 ]; then
    fetch "$(field cmake aarch64 url)" "$(field cmake aarch64 sha256)" cmake --strip-components=1
    fetch "$(field ninja aarch64 url)" "$(field ninja aarch64 sha256)" ninja
    chmod +x "$dest/ninja/ninja"
    for tool in cmake ctest cpack; do ln -sfn "../cmake/bin/$tool" "$dest/bin/$tool"; done
    ln -sfn ../ninja/ninja "$dest/bin/ninja"
fi

# The LLVM release's ld.lld needs libxml2.so.2, which current distributions
# (Fedora 44 included) no longer ship, and the sysroot's own pkgconf and
# wayland-scanner (aarch64 programs the build runs on aarch64) need
# libpkgconf, libexpat and libxml2. On aarch64 the sysroot has them all:
# bin/ld.lld, bin/pkgconf and bin/wayland-scanner run those programs with only
# these few libraries added, never the sysroot's glibc.
if [ "$arch" = aarch64 ]; then
    libs="$dest/ld-libs"
    mkdir -p "$libs"
    for lib in libxml2.so.2 libicuuc.so.74 libicudata.so.74 liblzma.so.5 libexpat.so.1 libpkgconf.so.3; do
        ln -sfn "../sysroot/usr/lib/aarch64-linux-gnu/$lib" "$libs/$lib"
    done
    for tool in llvm/bin/ld.lld sysroot/usr/bin/pkgconf sysroot/usr/bin/wayland-scanner; do
        rm -f "$dest/bin/${tool##*/}"
        cat > "$dest/bin/${tool##*/}" <<WRAPPER
#!/bin/sh
LD_LIBRARY_PATH="$libs\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" exec "$dest/$tool" "\$@"
WRAPPER
        chmod +x "$dest/bin/${tool##*/}"
    done
    "$dest/bin/pkgconf" --version
    "$dest/bin/wayland-scanner" --version
else
    ln -sfn ../llvm/bin/ld.lld "$dest/bin/ld.lld"
fi
"$dest/bin/ld.lld" --version
echo "Toolchain ready in $dest"
