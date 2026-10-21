// Build on macOS: clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Metal \
//   -framework IOSurface -framework IOKit tools/test_metal_surface_wait.m -o test_metal_surface_wait
// Run: ./test_metal_surface_wait [--timing [frames]] [event=0|event=1] [fault=query|fault=wait]
// Compare identical timing runs with old/new plugin AND NVK. Exit 0 pass, 1 fail, 77 skip.
// Internal wait counters make policy selection testable without a flaky CPU-time threshold.
#include "nvmtl_surface_probe.h"
#import <IOKit/IOKitLib.h>
#include <pthread.h>

static __thread unsigned observe_events, event_fault, event_queries, event_retries, event_faults;
static int (*wait_state)(void);
static kern_return_t (*original_scalar)(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
static kern_return_t probe_scalar(mach_port_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
static pthread_once_t scalar_once = PTHREAD_ONCE_INIT;
static void resolve_scalar(void) {
    original_scalar = dlsym(RTLD_NEXT, "IOConnectCallScalarMethod");
    if (!original_scalar || original_scalar == probe_scalar) {
        fprintf(stderr, "FAIL resolve original IOConnectCallScalarMethod\n"); exit(1);
    }
}
static kern_return_t probe_scalar(mach_port_t connection, uint32_t selector, const uint64_t *input,
                                  uint32_t inputCount, uint64_t *output, uint32_t *outputCount) {
    pthread_once(&scalar_once, resolve_scalar);
    if (observe_events && selector == 6 && input && inputCount == 2) {
        if (wait_state) check(wait_state() == 1, "event wait observes active scoped policy");
        if (!input[1]) event_queries++;
        if (input[1] == 200) event_retries++;
        if ((event_fault == 1 && !input[1]) || (event_fault == 2 && input[1] == 200)) {
            event_fault = 0; event_faults++; event_queries = event_retries = 0; return kIOReturnError;
        }
    }
    return original_scalar(connection, selector, input, inputCount, output, outputCount);
}
__attribute__((used)) static const struct { const void *replacement, *original; } interpose_scalar
    __attribute__((section("__DATA,__interpose"))) = {(const void *)probe_scalar, (const void *)IOConnectCallScalarMethod};

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
    // Release-plugin constructors clear inherited NVRM_*; override only after loading, before NVK initializes.
    void *plugin = dlopen("/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver", RTLD_NOW | RTLD_GLOBAL);
    if (!plugin) { fprintf(stderr, "SKIP installed NVMTL plugin unavailable\n"); return 77; }
    if (event) setenv("NVRM_EVENT_WAIT", event, 1);
    id<MTLDevice> d = device(); id<MTLCommandQueue> q = [d newCommandQueue];
    void (*wait_stats)(uint64_t *, unsigned) = dlsym(plugin, "nvmtl_vk_surface_wait_stats");
    check(wait_stats != NULL, "plugin exposes surface blocking policy counters (absent on old plugin)");
    wait_state = dlsym(plugin, "nvmtl_vk_surface_wait_state");
    check(wait_state != NULL, "plugin exposes current thread's wait policy");
    if (wait_state) check(wait_state() == 0, "upload thread starts with ordinary wait policy");
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
    event_queries = event_retries = event_faults = 0; event_fault = fault;
    double start = cpu_seconds();
    for (unsigned i = 0; i < frames; i++) @autoreleasepool {
        id<MTLTexture> t = (i & 1) ? tb : ta; IOSurfaceRef s = (i & 1) ? b : a;
        fill_surface(s, (unsigned char)i);
        observe_events = 1; surface_in(t); observe_events = 0;
        if (!timing && i < 32) {
            if (wait_state) check(wait_state() == 0, "each upload restores the calling thread's wait policy");
            verify(d, q, t, (unsigned char)i);
        }
    }
    printf("modified CPU_us/frame=%.3f frames=%u size=%lux%lu event=%s\n", (cpu_seconds() - start) * 1e6 / frames,
           frames, (unsigned long)w, (unsigned long)h, event ?: "default");
    if (wait_state) check(wait_state() == 0, "wait policy restored after the upload loop");
    [work waitUntilCompleted]; check(work.status == MTLCommandBufferStatusCompleted, "busy GPU completed");
    if (fault) {
        check(!event_fault && event_faults == 1, "inject exactly one selector-6 error on the upload thread");
        check(event_queries > 0 && event_retries > 0, "scoped event error permits a later scoped event wait");
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
    if (wait_state) check(wait_state() == 0, "wait policy restored after external edits and pending destruction");
    // Ordinary readback submissions should not create another upload scope.
    if (wait_stats) {
        wait_stats(before, 3); verify(d, q, ta, 41); wait_stats(after, 3);
        check(before[0] == after[0], "readback does not open another surface upload scope");
        if (wait_state) check(wait_state() == 0, "ordinary readback retains restored wait policy");
    }
    surface_in(nil); ta = nil; tb = nil; CFRelease(a); CFRelease(b);
    printf("%s surface blocking wait\n", failures ? "FAIL" : "PASS"); return failures ? 1 : 0;
} }
