# saints-reborn-arm64

Work towards running [Saints Reborn](https://github.com/whompay/SaintsReborn)
(Saints Row for Xbox 360, recompiled with the
[ReXGlue SDK](https://github.com/rexglue/rexglue-sdk)) natively on ARM64
Linux handhelds such as the Retroid Pocket 6 with ArmadaOS, the way
[pinyon-shift-arm64](https://github.com/Ken5998/pinyon-shift-arm64) does for
Pinyon Shift.

**Status:** Saints Reborn builds for linux-arm64: the ReXGlue SDK with Saints
Reborn's patch and the Vulkan backend, and the game itself. CI checks both
natively on ARM64 and cross-compiled on x86-64. Built from a disc on the
Retroid Pocket 6, it plays at 20-30 fps at the game's own 720p (see
[Performance](#performance)), and the build adds it to Steam with its
artwork. Next come the Vulkan versions of the fixes Saints Reborn made only
for D3D12, and a launcher ([docs/FEASIBILITY.md](docs/FEASIBILITY.md)).

This repository is an overlay: patches, scripts and CI only. It never
contains the game, files extracted from your disc, or the code and binaries
generated from them, and none may be published here.

## Not in the ARM64 build

- **Online co-op and online play over Epic.** Saints Reborn ships them as a
  Windows-only online pack; this port leaves them out.
- **Zombies and the native mods** (Whompay's Trainer, the native example):
  they are Windows DLLs.
- **Code hooks in Lua mods** (`wml.hook`). They are MinHook detours, which
  only exist for x86; on ARM64 the mod log says hooks are not supported yet.
  First Person (the V key), SixtyFPS and Living Stilwater need them. Lua
  mods that read and write game memory or patch game files work.
- **World Studio**, the Windows editor.

## What is here

| Path | What it does |
| --- | --- |
| `upstream.json` | The Saints Reborn commit and the SDK commit it pins, last verified here. |
| `toolchain.json` | LLVM 20.1.8, CMake, Ninja and the ARM64 sysroot from pinyon-shift-arm64, with their checksums. |
| `cmake/toolchains/linux-arm64.cmake` | Builds for aarch64 Linux against that sysroot, natively or from x86-64. |
| `patches/sdk/` | What linux-arm64 needs on top of Saints Reborn's `patches/rexglue-sdk.patch`. |
| `patches/game/` | Saints Reborn for linux-arm64: the build, the Windows-only parts, and a guest memory safety net for AArch64. |
| `scripts/build.sh ISO [DIR]` | Everything below, from your disc to a game folder ready to play. |
| `scripts/fetch-toolchain.sh DEST` | Downloads and checks the toolchain. |
| `scripts/prepare.sh WORKDIR [REF]` | Checks out Saints Reborn and its SDK commit and applies all the patches; files that come out the same keep their times (`scripts/keep-times.py`), so rebuilds stay small. |
| `scripts/build-sdk.sh SDK TOOLCHAIN` | Builds and installs the SDK for linux-arm64 with Vulkan. |
| `scripts/build-game.sh SR SDK TOOLCHAIN GENERATED` | Builds the game from the recompiled code. |
| `scripts/add-to-steam.sh [DIR]` | Adds the built game to Steam with its artwork (`tools/steam_art.cpp` draws it, `scripts/add-to-steam.py` writes the entry). |
| `scripts/placeholder-codegen.py SR SDK OUT` | Stand-in recompiled code, so CI can build the game without it (the result does not run). |
| `scripts/test-safety-net.sh SR SDK TOOLCHAIN` | Checks the safety net with fake guest memory, natively or under qemu. |
| `.github/workflows/ci.yml` | All of it without game files, natively on an ARM64 runner in Fedora 44 (the base of ArmadaOS) and cross-compiled on x86-64. |

## Building the game

You need your own Saints Row disc image (Xbox 360). On the handheld (ArmadaOS
included: only `git`, `python3`, `curl`, `tar` and `xz` are needed), from
Desktop Mode:

```bash
git clone https://github.com/Ken5998/saints-reborn-arm64
saints-reborn-arm64/scripts/build.sh "/path/to/Saints Row.iso"
```

It downloads the toolchain, builds the SDK, extracts the game from the disc,
recompiles it and builds it. That needs about 40 GB free and probably a few
hours on a handheld; run it again to resume, finished steps are skipped. The
game ends up in `~/.local/share/SaintsReborn-arm64/SaintsReborn/dist`.

To update, pull this repository and run the same command again: only what
the new patches change is recompiled, which takes minutes rather than hours.

At the end it adds **Saints Reborn** to the Steam library as a non-Steam game
(native, no Proton) with its artwork, drawn from Saints Reborn's own logo and
icon. Steam is closed for a moment and started again, since it would
otherwise overwrite the new entry; when the entry is already there it is left
alone, launch options included. For a game built before this existed:

```bash
git -C saints-reborn-arm64 pull
saints-reborn-arm64/scripts/add-to-steam.sh
```

Start the game from Steam: on ArmadaOS the handheld's controls reach a game
only when Steam launches it. For the GPU driver, Armada Control > Compatibility > Advanced > Drivers >
Turnip **Devel** is the one that gave Pinyon Shift its best performance.

On x86-64 Linux, `build.sh` works the same with `qemu-user` installed (CMake,
Ninja and `wayland-scanner` too); copy the `dist` folder to the handheld.

## Performance

Saints Row runs at up to **30 fps**, as on the Xbox 360: the game holds
itself there. Saints Reborn's SixtyFPS mod lifts that to 60, but it needs Lua
code hooks, which this port does not have yet.

On the Retroid Pocket 6 it played at 20-30 fps at 1280 x 720. ARM64
handhelds, whose GPU is part of the SoC, now start with lighter defaults:

- **OPTIONS > DISPLAY > Resolution (restart)**: 1280 x 720, the game's own
  resolution. 2x and 3x cost far too much here (about 10 fps at 2x), and a
  change applies the next time the game starts.
- **Shadows**: Low (shadow maps only, without the stencil shadows the CPU
  builds). **Off** gives the most frame rate; it applies at once.
- The GPU work is sent once per frame, and Turnip runs without shader
  preambles (`IR3_SHADER_DEBUG=nopreamble`, as Pinyon Shift's Android build
  sets on the same GPUs). Launch options in Steam can override that, e.g.
  `IR3_SHADER_DEBUG= %command%`.

Also pick Turnip **Devel** in Armada Control (see above).

### Upscaling

The frame is drawn at the resolution above, then stretched to the screen.
**OPTIONS > DISPLAY > Upscaling (restart)** picks how:

- **Bilinear**: the original, a little soft when stretched (the default at
  1280 x 720).
- **FSR 1**: AMD FidelityFX Super Resolution 1, an edge-preserving upscale
  and sharpening. Sharper on a 1080p screen for a small GPU cost.
- **CAS**: sharpening only (Contrast Adaptive Sharpening).

**Resolution > 960 x 540 (restart)** (experimental) draws 44 % fewer pixels
than 1280 x 720 and starts with FSR 1, for when the GPU holds the frame rate.
If its menus or HUD look wrong, go back to 1280 x 720.

To measure, create an empty file named `perf_log` in the game folder
(`~/.local/share/SaintsReborn-arm64/SaintsReborn/dist`), play for a couple of
minutes and look at `saintsrow_sdk.log` there: every 2 seconds a `PERF` line
gives the frame rate and frame times, the CPU use of the busiest threads and
the GPU clock against its highest, which tells whether the CPU or the GPU
holds the frame rate. Delete `perf_log` afterwards.

## License

Apache License 2.0, like Saints Reborn. See [NOTICE](NOTICE) for the credits.
