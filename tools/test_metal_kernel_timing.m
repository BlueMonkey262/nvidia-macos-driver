// CPU scheduling times must be available in scheduled handlers and remain stable afterwards.
// build: clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_kernel_timing tools/test_metal_kernel_timing.m
// run: ./test_metal_kernel_timing
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <time.h>

static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [d newCommandQueue];
        id<MTLSharedEvent> gate = [d newSharedEvent];
        id<MTLBuffer> out = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
        if (!q || !gate || !out) { fprintf(stderr, "PROBE_ERROR: setup\n"); return 2; }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        if (!cb) return 2;
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
        printf("PASS: scheduled CPU interval %.9f..%.9f remains readable\n", start, end);
        return 0;
    }
}
