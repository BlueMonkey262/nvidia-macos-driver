// CPU scheduling times must be available in scheduled handlers and remain stable afterwards.
// build: clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_kernel_timing tools/test_metal_kernel_timing.m
// run: ./test_metal_kernel_timing
// Also run with NVMTL_GSUB_INFLIGHT=0 and NVMTL_GSUB_INFLIGHT=16 (separate processes).
// exit: 0 pass / 1 fail / 77 skip. The foreign-event stand-in exercises NVMTL's error handling only.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <time.h>

static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d || ![NSStringFromClass([(id)d class]) hasPrefix:@"NVMTL"]) {
            fprintf(stderr, "SKIP: needs the NVMTL plugin\n"); return 77;
        }
        id<MTLCommandQueue> q = [d newCommandQueue];
        id<MTLSharedEvent> gate = [d newSharedEvent];
        id<MTLBuffer> out = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
        if (!q || !gate || !out) { fprintf(stderr, "FAIL: setup\n"); return 1; }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        if (!cb) return 1;
        if (cb.kernelStartTime || cb.kernelEndTime || cb.GPUStartTime || cb.GPUEndTime) return 1;
        id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
        [enc fillBuffer:out range:NSMakeRange(0, 16) value:7];
        [enc endEncoding];
        // The first part can schedule, but the command buffer cannot finish before the handler reads it.
        [cb encodeWaitForEvent:gate value:1];
        enc = [cb blitCommandEncoder];
        [enc fillBuffer:out range:NSMakeRange(0, 16) value:9];
        [enc endEncoding];
        __block double start = 0, end = 0;
        __block int failed = 0, called = 0;
        double before = now();
        [cb addScheduledHandler:^(id<MTLCommandBuffer> b) {
            start = b.kernelStartTime; end = b.kernelEndTime; called++;
            if (!(start >= before && end > start && end <= now())) failed = 1;
            if (b.GPUStartTime || b.GPUEndTime) failed = 1;
            gate.signaledValue = 1;
        }];
        [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted || called != 1 || failed ||
            cb.kernelStartTime != start || cb.kernelEndTime != end || ((uint8_t *)out.contents)[0] != 9) {
            NSLog(@"FAIL: schedule interval %.9f..%.9f, status %lu, %@",
                  start, end, (unsigned long)cb.status, cb.error);
            return 1;
        }
        for (unsigned i = 0; i < 3; i++) {
            if (cb.kernelStartTime != start || cb.kernelEndTime != end) return 1;
        }
        // A successful first part stamps both times, then signaling this foreign-event stand-in fails.
        // This triggers a CPU validation error after scheduling without causing device loss or a GPU fault.
        id<MTLCommandBuffer> bad = [q commandBuffer];
        enc = [bad blitCommandEncoder];
        if (!bad || !enc) return 1;
        [enc fillBuffer:out range:NSMakeRange(0, 16) value:11]; [enc endEncoding];
        [bad encodeSignalEvent:(id<MTLEvent>)[NSObject new] value:1];
        __block int completed = 0, errorTimes = 0;
        [bad addCompletedHandler:^(id<MTLCommandBuffer> b) {
            completed++;
            if (b.status != MTLCommandBufferStatusError || !b.error || b.kernelStartTime || b.kernelEndTime)
                errorTimes = 1;
        }];
        [bad commit]; [bad waitUntilCompleted];
        if (completed != 1 || errorTimes || bad.status != MTLCommandBufferStatusError || !bad.error) {
            NSLog(@"FAIL: expected post-scheduling foreign-event error, got %lu %@", (unsigned long)bad.status, bad.error);
            return 1;
        }
        for (unsigned i = 0; i < 3; i++) {
            if (bad.kernelStartTime || bad.kernelEndTime || bad.GPUStartTime || bad.GPUEndTime) return 1;
        }
        // An error must not poison the next buffer; an empty buffer also has no times before scheduling.
        id<MTLCommandBuffer> empty = [q commandBuffer];
        if (!empty || empty.kernelStartTime || empty.kernelEndTime) return 1;
        [empty commit]; [empty waitUntilCompleted];
        if (empty.status != MTLCommandBufferStatusCompleted || empty.kernelStartTime <= 0 ||
            empty.kernelEndTime < empty.kernelStartTime) return 1;
        printf("PASS: first-part CPU interval %.9f..%.9f stays readable; errored times are zero\n", start, end);
        return 0;
    }
}
