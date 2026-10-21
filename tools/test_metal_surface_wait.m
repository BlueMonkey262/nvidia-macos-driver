// Build on macOS: clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Metal \
//   -framework IOSurface tools/test_metal_surface_wait.m -o test_metal_surface_wait
// Run: ./test_metal_surface_wait [--timing [frames]] [event=0|event=1]
// Compare identical timing runs with old/new plugin AND NVK. Exit 0 pass, 1 fail, 77 skip.
// Internal wait counters make policy selection testable without a flaky CPU-time threshold.
#include "nvmtl_surface_probe.h"

int main(int argc, char **argv) { @autoreleasepool {
    int child = child_write(argc, argv); if (child >= 0) return child;
    BOOL timing = NO; unsigned frames = 128; const char *event = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--timing")) {
            timing = YES;
            if (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9') frames = (unsigned)strtoul(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "event=0") || !strcmp(argv[i], "event=1")) event = argv[i] + 6;
        else return 1;
    }
    if (!frames || frames > 1000000) return 1;
    // Release-plugin constructors clear inherited NVRM_*; override only after loading, before NVK initializes.
    void *plugin = dlopen("/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver", RTLD_NOW | RTLD_GLOBAL);
    if (!plugin) { fprintf(stderr, "SKIP installed NVMTL plugin unavailable\n"); return 77; }
    if (event) setenv("NVRM_EVENT_WAIT", event, 1);
    id<MTLDevice> d = device(); id<MTLCommandQueue> q = [d newCommandQueue];
    void (*wait_stats)(uint64_t *, unsigned) = dlsym(plugin, "nvmtl_vk_surface_wait_stats");
    check(wait_stats != NULL, "plugin exposes surface blocking policy counters (absent on old plugin)");
    uint64_t before[3] = {0}, after[3] = {0};
    if (wait_stats) {
        wait_stats(NULL, 0); // zero-length diagnostic query
        uint64_t padded[5] = {1, 1, 1, 1, 1}; wait_stats(padded, 5);
        check(!padded[3] && !padded[4], "diagnostic query zero-fills unknown counters");
        wait_stats(before, 3);
    }
    check(!wait_stats || before[0] != UINT64_MAX, "NVK supports scoped sleep policy (rebuild NVK too)");
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
    double start = cpu_seconds();
    for (unsigned i = 0; i < frames; i++) @autoreleasepool {
        id<MTLTexture> t = (i & 1) ? tb : ta; IOSurfaceRef s = (i & 1) ? b : a;
        fill_surface(s, (unsigned char)i); surface_in(t);
        if (!timing && i < 32) verify(d, q, t, (unsigned char)i);
    }
    printf("modified CPU_us/frame=%.3f frames=%u size=%lux%lu event=%s\n", (cpu_seconds() - start) * 1e6 / frames,
           frames, (unsigned long)w, (unsigned long)h, event ?: "default");
    [work waitUntilCompleted]; check(work.status == MTLCommandBufferStatusCompleted, "busy GPU completed");
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
    // Ordinary readback submissions after the upload must not inherit the thread-local policy.
    if (wait_stats) {
        wait_stats(before, 3); verify(d, q, ta, 41); wait_stats(after, 3);
        check(before[0] == after[0], "surface wait scope restored after upload");
    }
    surface_in(nil); ta = nil; tb = nil; CFRelease(a); CFRelease(b);
    printf("%s surface blocking wait\n", failures ? "FAIL" : "PASS"); return failures ? 1 : 0;
} }
