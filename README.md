# saints-reborn-arm64

Work towards running [Saints Reborn](https://github.com/whompay/SaintsReborn)
(Saints Row for Xbox 360, recompiled with the
[ReXGlue SDK](https://github.com/rexglue/rexglue-sdk)) natively on ARM64
Linux handhelds such as the Retroid Pocket 6 with ArmadaOS, the way
[pinyon-shift-arm64](https://github.com/Ken5998/pinyon-shift-arm64) does for
Pinyon Shift.

**Status:** the ReXGlue SDK, with Saints Reborn's patch, builds for
linux-arm64 with the Vulkan backend. The game itself does not build for ARM64
yet; [docs/FEASIBILITY.md](docs/FEASIBILITY.md) lists what is left.

This repository is an overlay: patches, scripts and CI only. It never
contains the game, files extracted from your disc, or the code and binaries
generated from them, and none may be published here.

## What is here

| Path | What it does |
| --- | --- |
| `upstream.json` | The Saints Reborn commit and the SDK commit it pins, last verified here. |
| `toolchain.json` | LLVM 20.1.8, CMake, Ninja and the ARM64 sysroot from pinyon-shift-arm64, with their checksums. |
| `cmake/toolchains/linux-arm64.cmake` | Builds for aarch64 Linux against that sysroot, natively or from x86-64. |
| `patches/sdk/` | What linux-arm64 needs on top of Saints Reborn's `patches/rexglue-sdk.patch`. |
| `scripts/fetch-toolchain.sh DEST` | Downloads and checks the toolchain. |
| `scripts/prepare-sdk.sh WORKDIR [REF]` | Checks out Saints Reborn and its SDK commit and applies both patches. |
| `scripts/build-sdk.sh SDK TOOLCHAIN` | Builds and installs the SDK for linux-arm64 with Vulkan. |
| `.github/workflows/ci.yml` | The same, natively on an ARM64 runner in Fedora 44 (the base of ArmadaOS) and cross-compiled on x86-64. |

## Building the SDK

On aarch64 Linux (ArmadaOS included: only `git`, `python3`, `curl`, `tar`
and `xz` are needed) or on x86-64 Linux with CMake, Ninja and
`wayland-scanner` installed:

```bash
scripts/fetch-toolchain.sh ~/sr-arm64/toolchain
scripts/prepare-sdk.sh ~/sr-arm64/work
scripts/build-sdk.sh ~/sr-arm64/work/rexglue-sdk ~/sr-arm64/toolchain
```

## License

Apache License 2.0, like Saints Reborn. See [NOTICE](NOTICE) for the credits.
