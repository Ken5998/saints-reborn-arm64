# Feasibility: Saints Reborn on linux-arm64

Checked on 2026-10-13 against Saints Reborn
[`46c6071`](https://github.com/whompay/SaintsReborn/commit/46c6071d0a0f51cf4cc8ca325f464b0e86727fee)
and the ReXGlue SDK commit it pins,
[`c94f5eb`](https://github.com/rexglue/rexglue-sdk/commit/c94f5ebdcb3c9d1a460ca48e04f9758448f8d518)
(v0.10.0). No game files were used.

## 1. The SDK builds for linux-arm64 with Vulkan

The upstream SDK already has a `linux-arm64` preset and a Vulkan backend
(about as large as its D3D12 one). Saints Reborn's
`patches/rexglue-sdk.patch` applies cleanly to it. With the patch, the build
fails in 7 files: Win32 calls outside `_WIN32` blocks (`GetTickCount64`,
`Sleep`, `__declspec(dllexport)`, Windows' `fd_set` and `select`, CNG for the
owner key) and one MSVC-only template lookup. `patches/sdk/` fixes them; the
rest of the patch compiles unchanged for aarch64.

`scripts/build-sdk.sh` builds the runtime, the Vulkan GPU plugin and the
`rexglue` recompiler for aarch64, natively on an aarch64 machine (CI: Fedora
44, as ArmadaOS) or cross-compiled on x86-64.

## 2. What the Saints Reborn SDK patch changes

`patches/rexglue-sdk.patch`: 65 files, +11,123 / -340 lines.

| Area | Added lines | On Vulkan |
| --- | ---: | --- |
| D3D12 backend only (13 files) | 4,370 | Not built. Needs porting where it matters (below). |
| Shared GPU code (command processor, shared memory, texture and render target caches, presenter) | 1,845 | Built and used as is. Only ever tested with D3D12. |
| Online: Xbox Live emulation, System Link, EOS lobby | 4,423 | Built, except `eos_lan.cpp` (2,007 lines, needs the EOS SDK). |
| Other (audio, file system, timers, input, codegen template) | 485 | Built as is. |

No file of the Vulkan backend is touched. The D3D12 additions, by what they
do (estimated from their comments and functions):

- **Fixes the game needs** (roughly 300-400 lines): unbound textures sample
  as opaque white instead of transparent black (materials otherwise go
  black), occlusion query begin/end handling, live resolution scale changes
  from the options menu, V-Sync from the options menu, gamma ramp. These have
  to be redone for Vulkan.
- **Mod visuals** (about 1,000 lines): Modern Look (sharpening, bloom,
  grading) and World Beams, compute and pixel shaders in HLSL called from mods
  through exported functions. Optional; the game falls back when the GPU
  plugin lacks them.
- **Performance and diagnostics** (the rest, about 3,000 lines): a replay
  thread for command lists, direct resolve snapshots, a render target update
  fast path, skipped colour/depth cross transfers, an experimental native
  renderer, GPU timing, barrier and shader statistics. Ported only if the
  handheld needs them.

## 3. The game code (`project/src`, `core/`)

- **x86 intrinsics**: 106 uses of 19 SSE intrinsics in 7 files
  (`native_math.inc`, `render_fixes.cpp`, `native_shadow.inc`,
  `render_overlap.inc`, `colour_split.inc`, `native_mesh.inc`, `cpu_gate.cpp`).
  The SDK already ships SIMDe, which maps all of them to NEON.
  `cpu_gate.cpp` (x86-64-v3 check) and the `-march=x86-64-v*` flags are
  replaced by an ARMv8 target.
- **Guest memory safety net** (`main.cpp`, about 380 lines in `_WIN32`): a
  Windows exception handler that decodes x86 instructions to turn the game's
  null and garbage pointer reads into zeros. Without it the game crashes
  where the console did not. Needs an AArch64 `SIGSEGV` version (fixed-size
  instructions make it simpler).
- **Windows APIs**: 22 of the 54 files in `project/src` use them; 12 already
  keep them all in `_WIN32` blocks, and a few more only call
  `GetTickCount64` or a couple of Win32 functions outside them. Real porting
  is needed in `world_studio_bridge.cpp`,
  `online_players.cpp`, `wml/mod_loader.cpp` (MinHook, x86 only),
  `online_integrity.cpp`, `stubs.cpp`, `main.cpp`, `render_fixes.cpp`, and in
  `core/WhompaysCoop/coop.cpp` (Winsock) and `core/Zombies/zombies.cpp`.
- **Build**: the CMake project is Windows-only in places (`WIN32`
  executable, `.rc` resources, `/ENTRY`, `/MAP`, `/force:multiple`, `/STACK`,
  `winmm`, `winhttp`, `ws2_32`). `/force:multiple` lets `stubs.cpp` replace
  SDK kernel exports; with the SDK as hidden-visibility shared libraries on
  Linux this needs checking.

## 4. Online co-op (EOS)

Online play over Epic is a separate "online pack" Saints Reborn publishes for
Windows x64 only (the Epic DLL, an EOS-enabled runtime and their `eos.ini`
credentials). Building it for ARM64 would need the EOS SDK for Linux ARM64
and credentials of a different Epic product, so ARM64 players would never
meet Windows players there. The patch already builds `eos_lan_off.cpp` when
the EOS SDK is missing: online over Epic is off, System Link still works on a
real LAN or VPN, and Whompay's co-op works by direct IP once its Winsock code
is ported. That is the plan here.

## 5. Reused from pinyon-shift-arm64

- LLVM 20.1.8, the ARM64 toolchain file and the `ld.lld` / libxml2 fix.
- The Ubuntu 24.04 arm64 sysroot release (`sysroot-2026.10.13.1`), unchanged.
- CI: native build on `ubuntu-24.04-arm` in Fedora 44, cross build on x86-64.
- The launcher idea (the handheld builds the game from the player's disc).
  Saints Reborn's own Setup (Rust, eframe) already runs on Linux and does
  the whole pipeline; teaching it a linux-arm64 target is likely less work
  than adapting Pinyon Shift's .NET launcher.
- Like Pinyon Shift's launcher, it should add the game to Steam as a
  non-Steam shortcut (no Proton), here with its artwork set (grid, hero,
  logo and icon in `userdata/<id>/config/grid`). No artwork is committed:
  Saints Reborn's icon is Apache 2.0; the rest is fetched at install time or
  made from the player's disc.
