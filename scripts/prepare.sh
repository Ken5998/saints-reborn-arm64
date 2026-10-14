#!/usr/bin/env bash
# Checks out Saints Reborn and the ReXGlue SDK commit it builds with, applies
# Saints Reborn's patches/rexglue-sdk.patch to the SDK, then this
# repository's patches/sdk/*.patch (what linux-arm64 needs on top), and
# patches/game/*.patch to Saints Reborn.
#
#   scripts/prepare.sh WORKDIR [SAINTS_REBORN_REF]
#
# WORKDIR/SaintsReborn  Saints Reborn at the commit in upstream.json (or REF),
#                       patched (its dist/ and build/ folders are left alone)
# WORKDIR/rexglue-sdk   the patched SDK
#
# No game files are involved.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mkdir -p "$1" && cd "$1" && pwd)"

field() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
        "$repo/upstream.json" "$1"
}
ref="${2:-$(field commit)}"
sr="$work/SaintsReborn"
sdk="$work/rexglue-sdk"

if [ ! -d "$sr/.git" ]; then
    git clone -q "$(field repository)" "$sr"
fi
git -C "$sr" fetch -q origin "$ref" 2>/dev/null || git -C "$sr" fetch -q origin
git -C "$sr" -c advice.detachedHead=false checkout -q --force "$ref"
# Files an earlier patch added; checkout --force leaves them.
git -C "$sr" clean -fdq -- project
echo "Saints Reborn $(git -C "$sr" rev-parse --short HEAD)"

# The SDK commit Saints Reborn pins, found as its own installer finds it.
sdk_commit=""
if [ -f "$sr/config/sdk_commit.txt" ]; then
    sdk_commit="$(tr -d '[:space:]' < "$sr/config/sdk_commit.txt")"
fi
if [ "${#sdk_commit}" -ne 40 ]; then
    sdk_commit="$(sed -n 's/^\$SdkCommit = "\([0-9a-f]\{40\}\)".*/\1/p' "$sr/scripts/setup.ps1" | head -n1)"
fi
if [ "${#sdk_commit}" -ne 40 ]; then
    echo "error: no ReXGlue SDK commit found in Saints Reborn" >&2
    exit 1
fi
if [ "$sdk_commit" != "$(field sdk_commit)" ]; then
    echo "note: Saints Reborn now pins SDK $sdk_commit (upstream.json: $(field sdk_commit))"
fi

if [ ! -d "$sdk/.git" ]; then
    git clone -q -c core.autocrlf=false "$(field sdk_repository)" "$sdk"
fi
git -C "$sdk" fetch -q origin "$sdk_commit" 2>/dev/null || true
git -C "$sdk" -c advice.detachedHead=false checkout -q --force "$sdk_commit"
# Files an earlier patch added; checkout --force leaves them.
git -C "$sdk" clean -fdq -- include src resources cmake
git -C "$sdk" submodule update --init --recursive --force --depth 1 -q ||
    git -C "$sdk" submodule update --init --recursive --force -q
echo "ReXGlue SDK $(git -C "$sdk" describe --tags --always)"

git -C "$sdk" apply --whitespace=nowarn "$sr/patches/rexglue-sdk.patch"
echo "Applied Saints Reborn's patches/rexglue-sdk.patch"
for patch in "$repo"/patches/sdk/*.patch; do
    [ -e "$patch" ] || continue
    git -C "$sdk" apply --whitespace=nowarn "$patch"
    echo "Applied ${patch#"$repo"/}"
done

for patch in "$repo"/patches/game/*.patch; do
    [ -e "$patch" ] || continue
    git -C "$sr" apply --whitespace=nowarn "$patch"
    echo "Applied ${patch#"$repo"/}"
done
