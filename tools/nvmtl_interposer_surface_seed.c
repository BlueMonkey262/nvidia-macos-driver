// Build/link commands live in test_metal_surface_seed.m. Load as a linked dylib, not executable code.
#include "nvmtl_interposer_surface.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

_Atomic int nvmtl_seed_fail_unlock, nvmtl_seed_omit_unlock_seed;
IOSurfaceRef nvmtl_seed_fault_surface;
static IOReturn (*original_unlock)(IOSurfaceRef, uint32_t, uint32_t *);
static IOReturn probe_unlock(IOSurfaceRef, uint32_t, uint32_t *);
static pthread_once_t unlock_once = PTHREAD_ONCE_INIT;
static __thread int in_unlock;
static void resolve_unlock(void) {
    original_unlock = dlsym(RTLD_NEXT, "IOSurfaceUnlock");
    if (!original_unlock || original_unlock == probe_unlock) {
        fprintf(stderr, "FAIL resolve original IOSurfaceUnlock\n"); exit(1);
    }
}
static IOReturn probe_unlock(IOSurfaceRef s, uint32_t options, uint32_t *seed) {
    if (in_unlock) { fprintf(stderr, "FAIL recursive IOSurfaceUnlock interposition\n"); exit(1); }
    in_unlock = 1; pthread_once(&unlock_once, resolve_unlock);
    int omit = s == nvmtl_seed_fault_surface && options == kIOSurfaceLockReadOnly
        && atomic_exchange(&nvmtl_seed_omit_unlock_seed, 0);
    IOReturn rc = original_unlock(s, options, omit ? NULL : seed);
    if (s == nvmtl_seed_fault_surface && options == kIOSurfaceLockReadOnly
        && atomic_exchange(&nvmtl_seed_fail_unlock, 0)) rc = kIOReturnError;
    in_unlock = 0; return rc;
}
__attribute__((used)) static const struct { const void *replacement, *original; } interpose_unlock
    __attribute__((section("__DATA,__interpose"))) = {(const void *)probe_unlock, (const void *)IOSurfaceUnlock};
