// Build on macOS, from the repo root (two steps; the dylib must stay beside the executable):
// clang -std=c11 -dynamiclib -framework IOKit -install_name @rpath/libnvmtl_surface_wait_interposer.dylib -o libnvmtl_surface_wait_interposer.dylib tools/nvmtl_interposer_surface_wait.c
// clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Metal -framework IOSurface -framework IOKit tools/test_metal_surface_wait.m libnvmtl_surface_wait_interposer.dylib -Wl,-rpath,@executable_path -o test_metal_surface_wait
// Harness: build the .c dylib separately without nm_shim.h; add its path and
// -Wl,-rpath,@executable_path to the existing .m build/link args (keep -include nm_shim.h).
// For a hand-loaded candidate, set NM_TEST_PLUGIN to its executable path so it is
// preloaded before the event override; diagnostics come from the selected device's image.
// Run: ./test_metal_surface_wait [--timing [frames]] [event=0|event=1] [fault=query|fault=wait]
// Exit 0 pass, 1 fail, 77 skip (including absent NVK hooks; rebuild Mesa/NVK first).
// Wait counters verify calls rather than a flaky CPU-time threshold; TLS state verifies restoration.
#include "nvmtl_surface_probe.h"
#include "nvmtl_interposer_surface.h"

int main(int argc, char **argv) { @autoreleasepool {
    int child = child_write(argc, argv); if (child >= 0) return child;
    BOOL timing = NO; unsigned frames = 128, fault = 0; const char *event = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--timing")) {
            timing = YES;
            if (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9') frames = (unsigned)strtoul(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "event=0") || !strcmp(argv[i], "event=1")) event = argv[i] + 6;
        else if (!strcmp(argv[i], "fault=query")) fault = 1;
        else if (!strcmp(argv[i], "fault=wait")) fault = 2;
        else return 1;
    }
    if (!frames || frames > 1000000 || (fault && (!event || strcmp(event, "1")))) return 1;
    // Release-plugin constructors clear inherited NVRM_*; preload the harness candidate before the override.
    const char *path = getenv("NM_TEST_PLUGIN");
    if (!path || !*path) path = "/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver";
    if (!dlopen(path, RTLD_NOW | RTLD_GLOBAL)) {
        fprintf(stderr, "SKIP cannot preload NVMTL plugin: %s\n", dlerror()); return 77;
    }
    if (event) setenv("NVRM_EVENT_WAIT", event, 1);
    id<MTLDevice> d = device();
    // The shim may select a hand-loaded device; query that image rather than the installed bundle.
    void *plugin = dlopen(class_getImageName(object_getClass(d)), RTLD_NOW | RTLD_LOCAL);
    void (*wait_stats)(uint64_t *, unsigned) = plugin ? dlsym(plugin, "nvmtl_vk_surface_wait_stats") : NULL;
    nvmtl_wait_state = plugin ? dlsym(plugin, "nvmtl_vk_surface_wait_state") : NULL;
    if (!wait_stats || !nvmtl_wait_state) {
        fprintf(stderr, "SKIP scoped-wait diagnostics absent; requires rebuilt plugin and Mesa/NVK hooks\n"); return 77;
    }
    uint64_t before[3] = {0}, after[3] = {0};
    wait_stats(before, 3);
    int initial_state = nvmtl_wait_state();
    if (before[0] == UINT64_MAX || initial_state < 0) {
        fprintf(stderr, "SKIP NVK scoped-wait hooks unavailable; rebuild Mesa/NVK before testing upload waits\n"); return 77;
    }
    check(initial_state == 0, "upload thread starts with ordinary wait policy");
    wait_stats(NULL, 0); // zero-length diagnostic query
    uint64_t padded[5] = {1, 1, 1, 1, 1}; wait_stats(padded, 5);
    check(!padded[3] && !padded[4], "diagnostic query zero-fills unknown counters");
    id<MTLCommandQueue> q = [d newCommandQueue];
    NSUInteger w = timing ? 1920 : 128, h = timing ? 1080 : 64;
    IOSurfaceRef a = make_surface(w, h), b = make_surface(w, h);
    if (!a || !b || !q) return 1;
    fill_surface(a, 17); fill_surface(b, 91);
    id<MTLTexture> ta = texture(d, a, w, h), tb = texture(d, b, w, h);
    // Put real GPU work ahead of the first import so a wait actually occurs, even at small surface sizes.
    id<MTLBuffer> busy = [d newBufferWithLength:32 * 1024 * 1024 options:MTLResourceStorageModePrivate];
    id<MTLCommandBuffer> work = [q commandBuffer]; id<MTLBlitCommandEncoder> bl = [work blitCommandEncoder];
    if (!busy || !work || !bl) return 1;
    for (unsigned i = 0; i < 64; i++) [bl fillBuffer:busy range:NSMakeRange(0, busy.length) value:(uint8_t)i];
    [bl endEncoding]; [work commit]; [work waitUntilScheduled];
    nvmtl_wait_event_queries = nvmtl_wait_event_retries = nvmtl_wait_event_faults = nvmtl_wait_policy_errors = 0;
    nvmtl_wait_event_fault = fault;
    double start = cpu_seconds();
    for (unsigned i = 0; i < frames; i++) @autoreleasepool {
        id<MTLTexture> t = (i & 1) ? tb : ta; IOSurfaceRef s = (i & 1) ? b : a;
        fill_surface(s, (unsigned char)i);
        nvmtl_wait_observe_events = 1; surface_in(t); nvmtl_wait_observe_events = 0;
        if (!timing && i < 32) {
            if (nvmtl_wait_state) check(nvmtl_wait_state() == 0, "each upload restores the calling thread's wait policy");
            verify(d, q, t, (unsigned char)i);
        }
    }
    printf("modified CPU_us/frame=%.3f frames=%u size=%lux%lu event=%s\n", (cpu_seconds() - start) * 1e6 / frames,
           frames, (unsigned long)w, (unsigned long)h, event ?: "default");
    check(!nvmtl_wait_policy_errors, "observed event waits use active scoped policy");
    check(nvmtl_wait_state() == 0, "wait policy restored after the upload loop");
    [work waitUntilCompleted]; check(work.status == MTLCommandBufferStatusCompleted, "busy GPU completed");
    if (fault) {
        check(!nvmtl_wait_event_fault && nvmtl_wait_event_faults == 1, "inject exactly one selector-6 error on the upload thread");
        check(nvmtl_wait_event_queries > 0 && nvmtl_wait_event_retries > 0, "scoped event error permits a later scoped event wait");
    }
    if (wait_stats) {
        wait_stats(after, 3);
        printf("scope_entries=%llu timed_sleeps=%llu event_waits=%llu\n", (unsigned long long)(after[0] - before[0]),
               (unsigned long long)(after[1] - before[1]), (unsigned long long)(after[2] - before[2]));
        check(after[0] != UINT64_MAX && after[0] - before[0] >= frames, "each modified-frame upload enters sleep scope");
        check(after[1] > before[1] || after[2] > before[2], "at least one scoped wait uses timed or event sleep");
        if (event && !strcmp(event, "0")) check(after[1] > before[1] && after[2] == before[2], "events disabled still use timed sleep");
    }
    verify(d, q, ta, (unsigned char)((frames - 1) & ~1u));
    verify(d, q, tb, frames > 1 ? (unsigned char)(((frames - 1) & 1) ? frames - 1 : frames - 2) : 91);
    uint64_t n = submits(); start = cpu_seconds();
    for (unsigned i = 0; i < frames; i++) { surface_in(ta); surface_in(tb); }
    printf("unchanged CPU_us/frame=%.3f frames=%u\n", (cpu_seconds() - start) * 1e6 / frames, frames);
    check(submits() == n, "unchanged surfaces do not wait or upload");
    external_write(argv[0], a, 41); surface_in(ta); verify(d, q, ta, 41);
    lifetime_cases(d, q);
    // Query actual TLS state; a 0-to-1 entry counter alone cannot expose a leaked scope.
    if (nvmtl_wait_state) check(nvmtl_wait_state() == 0, "wait policy restored after external edits and pending destruction");
    // Ordinary readback submissions should not create another upload scope.
    if (wait_stats) {
        wait_stats(before, 3); verify(d, q, ta, 41); wait_stats(after, 3);
        check(before[0] == after[0], "readback does not open another surface upload scope");
        if (nvmtl_wait_state) check(nvmtl_wait_state() == 0, "ordinary readback retains restored wait policy");
    }
    surface_in(nil); ta = nil; tb = nil; CFRelease(a); CFRelease(b);
    printf("%s surface blocking wait\n", failures ? "FAIL" : "PASS"); return failures ? 1 : 0;
} }
