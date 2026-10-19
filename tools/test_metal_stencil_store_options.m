// Legal stencil store options on descriptors, ordinary encoders, and parallel encoders.
// build: clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_stencil_store_options tools/test_metal_stencil_store_options.m
// run: ./test_metal_stencil_store_options
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static int check(id<MTLCommandQueue> q, id<MTLTexture> stencil, int mode, MTLStoreActionOptions options) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = stencil;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.stencilAttachment.texture = stencil;
    pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore;
    if (mode == 0) pass.stencilAttachment.storeActionOptions = options;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    if (!cb) return 1;
    if (mode == 2) {
        id<MTLParallelRenderCommandEncoder> p = [cb parallelRenderCommandEncoderWithDescriptor:pass];
        if (!p) return 1;
        [p setStencilStoreActionOptions:options];
        id<MTLRenderCommandEncoder> sub = [p renderCommandEncoder];
        [sub endEncoding]; [p endEncoding];
    } else {
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
        if (!e) return 1;
        if (mode == 1) [e setStencilStoreActionOptions:options];
        [e endEncoding];
    }
    [cb commit]; [cb waitUntilCompleted];
    BOOL unknown = (options & ~MTLStoreActionOptionCustomSamplePositions) != 0;
    BOOL ok = unknown ? cb.status == MTLCommandBufferStatusError : cb.status == MTLCommandBufferStatusCompleted;
    if (!ok) NSLog(@"FAIL: mode=%d options=%lu status=%lu error=%@", mode,
                  (unsigned long)options, (unsigned long)cb.status, cb.error);
    return !ok;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [d newCommandQueue];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                   width:8 height:8 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> stencil = [d newTextureWithDescriptor:td];
        if (!q || !stencil) { fprintf(stderr, "PROBE_ERROR: setup\n"); return 2; }
        int failed = 0;
        for (int mode = 0; mode < 3; mode++) {
            failed |= check(q, stencil, mode, MTLStoreActionOptionNone);
            failed |= check(q, stencil, mode, MTLStoreActionOptionCustomSamplePositions);
            failed |= check(q, stencil, mode, (MTLStoreActionOptions)(1u << 8));
        }
        if (failed) return 1;
        printf("PASS: legal stencil store options accepted, unknown bits rejected\n");
        return 0;
    }
}
