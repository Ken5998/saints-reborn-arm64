// Checks Saints Reborn's AArch64 guest memory safety net
// (project/src/guest_safety_net_posix.cpp, from patches/game/) on its own,
// with fake guest memory: the bad accesses the game makes turn into zeros and
// skipped instructions, a null call returns 0, traps are skipped, a fault it
// cannot fix ends a worker thread, and on the main thread still ends the
// process instead of hanging it.
//
// Built and run by scripts/test-safety-net.sh (natively or under qemu).

#include <arm_neon.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

#include "guest_safety_net.h"

namespace {

int g_failures = 0;

void Check(bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) ++g_failures;
}

uint8_t* g_base = nullptr;
uint64_t Guest(uint32_t address) { return reinterpret_cast<uint64_t>(g_base) + address; }

// A host address that is never mapped.
constexpr uint64_t kGarbage = 0x0000100000000000ull;

uint64_t LoadX(uint64_t address) {
    uint64_t value = 0x1111;
    asm volatile("ldr %0, [%1]" : "+r"(value) : "r"(address) : "memory");
    return value;
}

uint32_t LoadWBigEndian(uint64_t address) {
    uint32_t value = 0x1111;
    asm volatile("ldr %w0, [%1]\n\trev %w0, %w0" : "+r"(value) : "r"(address) : "memory");
    return value;
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    // The guest's 4 GB, mapped like the SDK maps it on Linux (read-write
    // views), then low pages protected the way released memory is.
    g_base = static_cast<uint8_t*>(mmap(nullptr, 0x100000000ull, PROT_READ | PROT_WRITE,
                                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0));
    if (g_base == MAP_FAILED) {
        std::perror("mmap");
        return 2;
    }
    mprotect(g_base, 0x10000000, PROT_NONE);
    mprotect(g_base + 0x40000000, 0x10000, PROT_NONE);

    // A fault it cannot fix on the main thread (installed from there) still
    // ends the process, instead of hanging it in a fault loop.
    {
        const pid_t child = fork();
        if (child == 0) {
            // Quiet: qemu reports the crash it is meant to have on stderr.
            dup2(open("/dev/null", O_WRONLY), 2);
            alarm(5);
            sr::InstallGuestSafetyNet(g_base);
            using Fn = void (*)();
            volatile uint64_t target = kGarbage;
            reinterpret_cast<Fn>(target)();
            _exit(0);
        }
        int status = 0;
        waitpid(child, &status, 0);
        Check(WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV,
              "unfixable fault on the main thread ends the process with SIGSEGV (no hang)");
    }

    sr::InstallGuestSafetyNet(g_base);

    Check(LoadX(Guest(0x100)) == 0, "near-null guest read gives 0 (zero region)");
    Check(LoadWBigEndian(Guest(0x02000010)) == 0, "low guest read gives 0 and is skipped");
    {
        uint64_t value = 0x2222;
        asm volatile("str %0, [%1]" : : "r"(value), "r"(Guest(0x03000000)) : "memory");
        Check(true, "low guest write is skipped");
    }
    {
        const uint64_t address = Guest(0x40000020);
        Check(LoadX(address) == 0, "protected guest page is committed on demand");
        *reinterpret_cast<volatile uint32_t*>(address) = 0x12345678;
        Check(*reinterpret_cast<volatile uint32_t*>(address) == 0x12345678,
              "and is writable afterwards");
    }
    Check(LoadX(kGarbage) == 0, "garbage host pointer read gives 0");
    {
        uint64_t a = 1, b = 2, address = kGarbage;
        asm volatile("ldp %0, %1, [%2], #16" : "+r"(a), "+r"(b), "+r"(address) : : "memory");
        Check(a == 0 && b == 0 && address == kGarbage + 16, "ldp post-index: both zero, base moved");
    }
    {
        uint64_t value = 7, address = kGarbage;
        asm volatile("ldr %0, [%1, #-8]!" : "+r"(value), "+r"(address) : : "memory");
        Check(value == 0 && address == kGarbage - 8, "ldr pre-index: zero, base moved");
    }
    {
        uint32x4_t v = vdupq_n_u32(5);
        asm volatile("ldr %q0, [%1]" : "+w"(v) : "r"(kGarbage) : "memory");
        Check(vmaxvq_u32(v) == 0, "ldr q: vector zeroed");
        v = vdupq_n_u32(5);
        uint64_t address = kGarbage;
        asm volatile("ld1 {%0.4s}, [%1], #16" : "+w"(v), "+r"(address) : : "memory");
        Check(vmaxvq_u32(v) == 0 && address == kGarbage + 16, "ld1 post-index: zeroed, base moved");
        v = vdupq_n_u32(5);
        asm volatile("ld1 {%0.s}[2], [%1]" : "+w"(v) : "r"(kGarbage) : "memory");
        Check(vgetq_lane_u32(v, 2) == 0 && vgetq_lane_u32(v, 0) == 5 && vgetq_lane_u32(v, 3) == 5,
              "ld1 lane: only that lane zeroed");
    }
    {
        // Recompiled code uses CAS for lwarx/stwcx, not exclusive pairs, so only
        // the exclusive load is checked: a store exclusive after a skipped one
        // has no monitor and may just fail without faulting.
        uint32_t loaded = 9, value = 3;
        asm volatile("ldaxr %w0, [%1]" : "+r"(loaded) : "r"(kGarbage) : "memory");
        Check(loaded == 0, "ldaxr: zero");
        uint32_t expected = 4;
        asm volatile("casal %w0, %w1, [%2]" : "+r"(expected) : "r"(value), "r"(kGarbage) : "memory");
        Check(expected == 0, "casal: old value zero");
        uint32_t old = 8;
        asm volatile("ldadd %w1, %w0, [%2]" : "=&r"(old) : "r"(value), "r"(kGarbage) : "memory");
        Check(old == 0, "ldadd: old value zero");
    }
    {
        using Fn = uint64_t (*)();
        volatile uint64_t null_target = 0;
        Fn fn = reinterpret_cast<Fn>(null_target);
        Check(fn() == 0, "call through a null pointer returns 0");
        Fn object = reinterpret_cast<Fn>(Guest(0x0F000040));
        Check(object() == 0, "call into the null object page returns 0");
        uint64_t last = 0;
#pragma clang loop unroll(disable)
        for (int i = 0; i < 25; ++i) last = fn();
        Check(last == 1, "the same null call repeated returns 1 after 20 times");
    }
    {
        asm volatile("brk #1");
        asm volatile("brk #0xf000");
        Check(true, "__builtin_trap / __builtin_debugtrap (brk) are skipped");
    }
    {
        pthread_t thread;
        pthread_create(
            &thread, nullptr,
            [](void*) -> void* {
                using Fn = void (*)();
                volatile uint64_t target = kGarbage;  // not near null: nothing to fix
                reinterpret_cast<Fn>(target)();
                return reinterpret_cast<void*>(1);
            },
            nullptr);
        void* result = reinterpret_cast<void*>(2);
        pthread_join(thread, &result);
        Check(result == nullptr, "worker thread with a fault it cannot fix ends (pthread_exit)");
    }
    std::printf("%s\n", g_failures ? "SOME CHECKS FAILED" : "all checks passed");
    return g_failures ? 1 : 0;
}
