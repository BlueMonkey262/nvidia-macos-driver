// Build on macOS, from the repo root (two steps; the dylib must stay beside the executable):
// clang -std=c11 -dynamiclib -framework IOSurface -install_name @rpath/libnvmtl_surface_seed_interposer.dylib -o libnvmtl_surface_seed_interposer.dylib tools/nvmtl_interposer_surface_seed.c
// clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Metal -framework IOSurface tools/test_metal_surface_seed.m libnvmtl_surface_seed_interposer.dylib -Wl,-rpath,@executable_path -o test_metal_surface_seed
// Harness: build the .c dylib separately without nm_shim.h; add its path and
// -Wl,-rpath,@executable_path to the existing .m build/link args (keep -include nm_shim.h).
// Run: ./test_metal_surface_seed [--timing [frames]]
// Exit 0 pass, 1 fail, 77 skip. Ordinary skip cases already passed the old plugin;
// the linked interposer makes the unlock-error retry discriminate old/new.
#include "nvmtl_surface_probe.h"
#include "nvmtl_interposer_surface.h"

int main(int argc, char **argv) { @autoreleasepool {
    int child = child_write(argc, argv); if (child >= 0) return child;
    BOOL timing = argc > 1 && !strcmp(argv[1], "--timing");
    unsigned frames = timing && argc > 2 ? (unsigned)strtoul(argv[2], NULL, 10) : 1000;
    if (!frames || frames > 1000000) return 1;
    id<MTLDevice> d = device(); id<MTLCommandQueue> q = [d newCommandQueue];
    NSUInteger w = timing ? 1920 : 64, h = timing ? 1080 : 16;
    IOSurfaceRef a = make_surface(w, h), b = make_surface(w, h);
    if (!a || !b || !q) return 1;
    fill_surface(a, 21); fill_surface(b, 89);
    id<MTLTexture> ta = texture(d, a, w, h), tb = texture(d, b, w, h);
    surface_in(ta); surface_in(tb);
    uint64_t n = submits(); double start = cpu_seconds();
    for (unsigned i = 0; i < frames; i++) { surface_in(ta); surface_in(tb); }
    double elapsed = cpu_seconds() - start;
    printf("unchanged CPU_us/frame=%.3f frames=%u uploads=%llu (two surfaces/frame)\n", elapsed * 1e6 / frames, frames, (unsigned long long)(submits() - n));
    check(submits() == n, "unchanged surfaces submit no uploads across many frames");
    verify(d, q, ta, 21); verify(d, q, tb, 89);
    // Read-only CPU access preserves the cache. Writable access must invalidate it.
    check(IOSurfaceLock(a, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess, "read-only CPU lock");
    check(IOSurfaceUnlock(a, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess, "read-only CPU unlock");
    n = submits(); surface_in(ta); check(submits() == n, "read-only lock does not re-upload");
    uint32_t seed = IOSurfaceGetSeed(a); fill_surface(a, 44);
    check(IOSurfaceGetSeed(a) != seed, "CPU write unlock changes seed");
    n = submits(); surface_in(ta); check(submits() > n, "CPU-modified surface uploads"); verify(d, q, ta, 44);
    verify(d, q, tb, 89);
    external_write(argv[0], a, 67); n = submits(); surface_in(ta);
    check(submits() > n, "cross-process modification uploads"); verify(d, q, ta, 67);
    // Finish the real unlock, then report an error once. The plugin must leave its cache invalid.
    fill_surface(a, 72); nvmtl_seed_fault_surface = a; atomic_store(&nvmtl_seed_fail_unlock, 1); surface_in(ta);
    check(!atomic_load(&nvmtl_seed_fail_unlock), "read-only unlock fault reached import");
    nvmtl_seed_fault_surface = NULL; n = submits(); surface_in(ta);
    check(submits() > n, "failed unlock retries import rather than caching uncertain state"); verify(d, q, ta, 72);
    // Model a successful read-only unlock that leaves its seed out-parameter untouched.
    fill_surface(a, 84); nvmtl_seed_fault_surface = a; atomic_store(&nvmtl_seed_omit_unlock_seed, 1); surface_in(ta);
    check(!atomic_load(&nvmtl_seed_omit_unlock_seed), "read-only unlock omitted seed once");
    nvmtl_seed_fault_surface = NULL; n = submits(); surface_in(ta);
    check(submits() == n, "unwritten unlock seed preserves unchanged-surface skip"); verify(d, q, ta, 84);
    start = cpu_seconds();
    for (unsigned i = 0; i < frames; i++) { fill_surface(a, (unsigned char)i); surface_in(ta); }
    printf("modified CPU_us/frame=%.3f frames=%u\n", (cpu_seconds() - start) * 1e6 / frames, frames);
    verify(d, q, ta, (unsigned char)(frames - 1));
    lifetime_cases(d, q);
    ta = nil; tb = nil; CFRelease(a); CFRelease(b);
    // nil/non-surface receivers are legal for this internal import helper.
    surface_in(nil);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
    surface_in([d newTextureWithDescriptor:td]);
    printf("%s surface seed cache\n", failures ? "FAIL" : "PASS"); return failures ? 1 : 0;
} }
