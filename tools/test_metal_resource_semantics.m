// Public-API checks for resource / command-buffer / blit semantics fixed in the RESOURCES theme.
// Build and run on the macOS machine (default Metal device):
//   clang -fobjc-arc -framework Foundation -framework Metal -o test_metal_resource_semantics \
//     tools/test_metal_resource_semantics.m && ./test_metal_resource_semantics
// Exit 0 on success; non-zero with FAIL lines on mismatch.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

static int gFails;

static void expect(int ok, const char *name) {
    if (ok) printf("PASS %s\n", name);
    else { printf("FAIL %s\n", name); gFails++; }
    fflush(stdout);
}

static NSUInteger mipDim(NSUInteger base, NSUInteger level) {
    NSUInteger v = base >> level; return v ? v : 1;
}

static void fillLevel(id<MTLTexture> t, NSUInteger level, uint8_t v) {
    NSUInteger w = mipDim(t.width, level), h = mipDim(t.height, level);
    NSUInteger bpr = w * 4;
    NSMutableData *px = [NSMutableData dataWithLength:bpr * h];
    memset(px.mutableBytes, v, px.length);
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:level withBytes:px.bytes bytesPerRow:bpr];
}

static uint8_t sampleLevel(id<MTLTexture> t, NSUInteger level) {
    NSUInteger w = mipDim(t.width, level), h = mipDim(t.height, level);
    NSUInteger bpr = w * 4;
    NSMutableData *px = [NSMutableData dataWithLength:bpr * h];
    [t getBytes:px.mutableBytes bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:level];
    return ((const uint8_t *)px.bytes)[0];
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) { fprintf(stderr, "no Metal device\n"); return 2; }
        printf("DEVICE %s class=%s\n", d.name.UTF8String, NSStringFromClass(d.class).UTF8String);
        id<MTLCommandQueue> q = [d newCommandQueue];
        if (!q) { fprintf(stderr, "no command queue\n"); return 3; }

        // retainedReferences / errorOptions from creation APIs
        {
            id<MTLCommandBuffer> a = [q commandBuffer];
            expect(a.retainedReferences == YES, "commandBuffer retainedReferences YES");
            id<MTLCommandBuffer> u = [q commandBufferWithUnretainedReferences];
            expect(u.retainedReferences == NO, "commandBufferWithUnretainedReferences retainedReferences NO");
            if (@available(macOS 11.0, *)) {
                MTLCommandBufferDescriptor *desc = [MTLCommandBufferDescriptor new];
                desc.retainedReferences = NO;
                desc.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
                id<MTLCommandBuffer> c = [q commandBufferWithDescriptor:desc];
                expect(c.retainedReferences == NO, "descriptor retainedReferences NO");
                expect(c.errorOptions == MTLCommandBufferErrorOptionEncoderExecutionStatus,
                       "descriptor errorOptions EncoderExecutionStatus");
            }
        }

        // kernelStartTime / kernelEndTime: 0 until completed; then schedule-window host times
        {
            id<MTLCommandBuffer> c = [q commandBuffer];
            id<MTLBlitCommandEncoder> b = [c blitCommandEncoder];
            [b endEncoding];
            expect(c.kernelStartTime == 0 && c.kernelEndTime == 0, "kernel times zero before complete");
            [c commit];
            [c waitUntilCompleted];
            expect(c.status == MTLCommandBufferStatusCompleted, "kernel-time CB completed");
            expect(c.kernelStartTime > 0 && c.kernelEndTime > 0, "kernel times set after complete");
            expect(c.kernelEndTime >= c.kernelStartTime, "kernelEndTime >= kernelStartTime");
        }

        // residency set: add twice, unique count
        if ([d respondsToSelector:@selector(newResidencySetWithDescriptor:error:)]) {
            MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
            NSError *err = nil;
            id<MTLResidencySet> rs = [d newResidencySetWithDescriptor:rd error:&err];
            id<MTLBuffer> buf = [d newBufferWithLength:64 options:MTLResourceStorageModeShared];
            if (rs && buf) {
                [rs addAllocation:(id<MTLAllocation>)buf];
                [rs addAllocation:(id<MTLAllocation>)buf];
                [rs commit];
                expect(rs.allocationCount == 1, "residency addAllocation uniqueness");
            } else {
                printf("SKIP residency set unavailable\n");
            }
        } else {
            printf("SKIP residency set API absent\n");
        }

        // Private buffer contents is NULL
        {
            id<MTLBuffer> priv = [d newBufferWithLength:256 options:MTLResourceStorageModePrivate];
            expect(priv != nil && priv.contents == NULL, "Private buffer contents nil");
        }

        // allowGPUOptimizedContents mirrors descriptor
        {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:8 height:8 mipmapped:NO];
            td.allowGPUOptimizedContents = NO;
            id<MTLTexture> t = [d newTextureWithDescriptor:td];
            expect(t != nil && t.allowGPUOptimizedContents == NO, "allowGPUOptimizedContents NO");
            td.allowGPUOptimizedContents = YES;
            id<MTLTexture> t2 = [d newTextureWithDescriptor:td];
            expect(t2 != nil && t2.allowGPUOptimizedContents == YES, "allowGPUOptimizedContents YES");
        }

        // rootResource: view of texture -> root texture; view of buffer-backed -> buffer
        {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:8 height:8 mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            id<MTLTexture> root = [d newTextureWithDescriptor:td];
            id<MTLTexture> view1 = [root newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
            id<MTLTexture> view2 = [view1 newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
            expect(view2.parentTexture == view1, "parentTexture is immediate view parent");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            expect(view2.rootResource == (id)root, "rootResource nested view -> storage root");
#pragma clang diagnostic pop
            id<MTLBuffer> bb = [d newBufferWithLength:8 * 8 * 4 options:MTLResourceStorageModeShared];
            MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:8 height:8 mipmapped:NO];
            bd.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> bt = [bb newTextureWithDescriptor:bd offset:0 bytesPerRow:32];
            if (bt)
                expect(bt.rootResource == (id)bb, "rootResource buffer texture -> buffer");
            else
                printf("SKIP buffer texture unavailable\n");
        }

        // ICB allocatedSize non-zero
        if ([d respondsToSelector:@selector(newIndirectCommandBufferWithDescriptor:maxCommandCount:options:)]) {
            MTLIndirectCommandBufferDescriptor *idesc = [MTLIndirectCommandBufferDescriptor new];
            idesc.commandTypes = MTLIndirectCommandTypeConcurrentDispatch;
            idesc.inheritBuffers = NO;
            idesc.maxKernelBufferBindCount = 4;
            id<MTLIndirectCommandBuffer> icb = [d newIndirectCommandBufferWithDescriptor:idesc maxCommandCount:4 options:0];
            if (icb)
                expect(icb.allocatedSize > 0, "ICB allocatedSize > 0");
            else
                printf("SKIP ICB create failed\n");
        }

        // blit copyFromTexture:toTexture: copies every mip level
        {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:16 height:16 mipmapped:YES];
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> src = [d newTextureWithDescriptor:td];
            id<MTLTexture> dst = [d newTextureWithDescriptor:td];
            NSUInteger n = src.mipmapLevelCount;
            expect(n > 1, "mipmapped textures have multiple levels");
            for (NSUInteger l = 0; l < n; l++) fillLevel(src, l, (uint8_t)(0x10 + l));
            for (NSUInteger l = 0; l < n; l++) fillLevel(dst, l, 0xCD);
            id<MTLCommandBuffer> c = [q commandBuffer];
            id<MTLBlitCommandEncoder> bl = [c blitCommandEncoder];
            [bl copyFromTexture:src toTexture:dst];
            [bl endEncoding];
            [c commit];
            [c waitUntilCompleted];
            expect(c.error == nil, "copyFromTexture:toTexture: completed");
            int all = 1;
            for (NSUInteger l = 0; l < n; l++)
                if (sampleLevel(dst, l) != (uint8_t)(0x10 + l)) all = 0;
            expect(all, "copyFromTexture:toTexture: every mip level copied");
        }

        // blit buffer->texture writes only the given level (no auto mipgen)
        {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:16 height:16 mipmapped:YES];
            td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            td.storageMode = MTLStorageModeShared;
            id<MTLTexture> tex = [d newTextureWithDescriptor:td];
            NSUInteger n = tex.mipmapLevelCount;
            for (NSUInteger l = 0; l < n; l++) fillLevel(tex, l, 0xAB);
            NSUInteger bpr = 16 * 4;
            id<MTLBuffer> src = [d newBufferWithLength:bpr * 16 options:MTLResourceStorageModeShared];
            memset(src.contents, 0x22, bpr * 16);
            id<MTLCommandBuffer> c = [q commandBuffer];
            id<MTLBlitCommandEncoder> bl = [c blitCommandEncoder];
            [bl copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:bpr sourceBytesPerImage:bpr * 16
                    sourceSize:MTLSizeMake(16, 16, 1) toTexture:tex destinationSlice:0 destinationLevel:0
             destinationOrigin:MTLOriginMake(0, 0, 0)];
            [bl endEncoding];
            [c commit];
            [c waitUntilCompleted];
            expect(c.error == nil, "buffer-to-texture blit completed");
            expect(sampleLevel(tex, 0) == 0x22, "buffer-to-texture wrote level 0");
            int others = 1;
            for (NSUInteger l = 1; l < n; l++)
                if (sampleLevel(tex, l) != 0xAB) others = 0;
            expect(others, "buffer-to-texture left other mip levels unchanged");
        }

        // parallel encoder: CustomSamplePositions stencil options must not Internal-error the CB
        {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:8 height:8 mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> color = [d newTextureWithDescriptor:td];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = color;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            id<MTLCommandBuffer> c = [q commandBuffer];
            id<MTLParallelRenderCommandEncoder> pre = [c parallelRenderCommandEncoderWithDescriptor:pass];
            if (pre) {
                [pre setStencilStoreActionOptions:MTLStoreActionOptionCustomSamplePositions];
                id<MTLRenderCommandEncoder> sub = [pre renderCommandEncoder];
                [sub endEncoding];
                [pre endEncoding];
                [c commit];
                [c waitUntilCompleted];
                expect(!(c.error && c.error.code == MTLCommandBufferErrorInternal
                         && [c.error.localizedDescription containsString:@"stencil"]),
                       "parallel setStencilStoreActionOptions CustomSamplePositions no Internal");
            } else {
                printf("SKIP parallel render encoder\n");
            }
        }

        printf("RESULT fails=%d\n", gFails);
        return gFails ? 1 : 0;
    }
}
