// Build: xcrun clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_client_census tools/test_metal_client_census.m
// Run: ./test_metal_client_census (or the run_theme.sh hand-loaded plugin harness).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "../plugin/nvmtl_client_census.h"

static void census(const char *phase, NSUInteger round, NSUInteger count)
{
    char snapshot[384]; nvmtl_client_census_snapshot(snapshot, sizeof snapshot);
    printf("client census probe: round=%lu %s count=%lu %s\n", (unsigned long)round, phase, (unsigned long)count, snapshot);
    fflush(stdout);
}

int main(void)
{
    @autoreleasepool {
        census("before-device", 0, 0);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "PROBE_ERROR: no Metal device\n"); return 2; }
        printf("device=%s class=%s\n", device.name.UTF8String, NSStringFromClass([(id)device class]).UTF8String);
        census("after-device", 0, 0);
        const NSUInteger lengths[] = {16, 64, 256, 4096, 65536, 1u << 20};
        const NSUInteger widths[] = {8, 16, 32, 64, 128, 256};
        for (NSUInteger round = 1; round <= 3; round++) {
            // Keep both storage modes alive together, then drain ARC/autoreleased objects
            // before the next census. Repetition exposes caches and persistent growth.
            @autoreleasepool {
                NSMutableArray *buffers = [NSMutableArray new];
                for (NSUInteger mode = 0; mode < 2; mode++) {
                    for (NSUInteger i = 0; i < 150; i++) {
                        @autoreleasepool {
                            MTLResourceOptions options = mode ? MTLResourceStorageModePrivate : MTLResourceStorageModeShared;
                            id<MTLBuffer> b = [device newBufferWithLength:lengths[i % 6] options:options];
                            if (!b) { census("buffer-failed", round, buffers.count); return 1; }
                            if (!mode) {
                                void *contents = b.contents;
                                if (!contents) { census("shared-contents-failed", round, buffers.count); return 1; }
                                memset(contents, 0x5a, lengths[i % 6]);
                            }
                            [buffers addObject:b];
                        }
                        if ((i + 1) % 50 == 0) census(mode ? "private-buffers" : "shared-buffers", round, buffers.count);
                    }
                }
                [buffers removeAllObjects];
            }
            census("buffers-released", round, 0);
            @autoreleasepool {
                NSMutableArray *textures = [NSMutableArray new];
                for (NSUInteger mode = 0; mode < 2; mode++) {
                    for (NSUInteger i = 0; i < 150; i++) {
                        @autoreleasepool {
                            NSUInteger width = widths[i % 6];
                            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                width:width height:width mipmapped:NO];
                            td.storageMode = mode ? MTLStorageModePrivate : MTLStorageModeShared;
                            td.usage = MTLTextureUsageShaderRead;
                            id<MTLTexture> t = [device newTextureWithDescriptor:td];
                            if (!t) { census("texture-failed", round, textures.count); return 1; }
                            [textures addObject:t];
                        }
                        if ((i + 1) % 50 == 0) census(mode ? "private-textures" : "shared-textures", round, textures.count);
                    }
                }
                [textures removeAllObjects];
            }
            census("textures-released", round, 0);
        }
        printf("DONE: three rounds of 300 buffers and 300 textures; compare per-class deltas\n");
        return 0;
    }
}
