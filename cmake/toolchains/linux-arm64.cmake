# Builds the ReXGlue SDK (and later Saints Reborn) for aarch64 Linux with
# LLVM 20.1.8, against the pinned Ubuntu 24.04 arm64 sysroot that
# pinyon-shift-arm64 publishes. Works natively on aarch64 and as a cross
# build on x86-64; the result runs on Fedora 44 (ArmadaOS) and newer.
#
# SR_ARM64_TOOLCHAIN (cache or environment) holds:
#   llvm/        LLVM 20.1.8 for the build host
#   sysroot/     the pinned sysroot (toolchain.json)
#   bin/         ld.lld that runs on this host and, on aarch64, the sysroot's
#                pkgconf and wayland-scanner made to run here
# scripts/fetch-toolchain.sh sets it up.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT SR_ARM64_TOOLCHAIN)
  set(SR_ARM64_TOOLCHAIN "$ENV{SR_ARM64_TOOLCHAIN}")
endif()
if(NOT EXISTS "${SR_ARM64_TOOLCHAIN}/llvm/bin/clang")
  message(FATAL_ERROR "SR_ARM64_TOOLCHAIN must hold llvm/ and sysroot/ (scripts/fetch-toolchain.sh)")
endif()
set(SR_ARM64_TOOLCHAIN "${SR_ARM64_TOOLCHAIN}" CACHE PATH "LLVM and sysroot for linux-arm64")
# try_compile projects see the variable too.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES SR_ARM64_TOOLCHAIN)

set(_sr_llvm "${SR_ARM64_TOOLCHAIN}/llvm/bin")
set(CMAKE_C_COMPILER "${_sr_llvm}/clang")
set(CMAKE_CXX_COMPILER "${_sr_llvm}/clang++")
set(CMAKE_AR "${_sr_llvm}/llvm-ar" CACHE FILEPATH "")
set(CMAKE_RANLIB "${_sr_llvm}/llvm-ranlib" CACHE FILEPATH "")
foreach(_lang C CXX ASM)
  set(CMAKE_${_lang}_COMPILER_TARGET aarch64-linux-gnu)
endforeach()

set(CMAKE_SYSROOT "${SR_ARM64_TOOLCHAIN}/sysroot")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${CMAKE_SYSROOT}")
set(ENV{PKG_CONFIG_LIBDIR}
    "${CMAKE_SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${CMAKE_SYSROOT}/usr/share/pkgconfig")
set(ENV{PKG_CONFIG_PATH} "")
# The sysroot's own pkgconf and wayland-scanner are aarch64 programs: used on
# an aarch64 host (ArmadaOS has neither) through fetch-toolchain.sh's wrappers,
# the build host's on x86-64.
if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
  if(NOT PKG_CONFIG_EXECUTABLE AND EXISTS "${SR_ARM64_TOOLCHAIN}/bin/pkgconf")
    set(PKG_CONFIG_EXECUTABLE "${SR_ARM64_TOOLCHAIN}/bin/pkgconf" CACHE FILEPATH "")
  endif()
  if(NOT WAYLAND_SCANNER AND EXISTS "${SR_ARM64_TOOLCHAIN}/bin/wayland-scanner")
    set(WAYLAND_SCANNER "${SR_ARM64_TOOLCHAIN}/bin/wayland-scanner" CACHE FILEPATH "")
  endif()
endif()

# libstdc++ is linked statically, so a newer GCC on the build machine never
# needs a newer library on the handheld.
set(_sr_link "-fuse-ld=lld -static-libstdc++")
if(EXISTS "${SR_ARM64_TOOLCHAIN}/bin/ld.lld")
  string(APPEND _sr_link " --ld-path=${SR_ARM64_TOOLCHAIN}/bin/ld.lld")
endif()
set(CMAKE_EXE_LINKER_FLAGS_INIT "${_sr_link}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_sr_link}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_sr_link}")
