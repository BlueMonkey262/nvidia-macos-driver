// ICB blit copies/resets must precede later executes on the command-buffer timeline.
// Build and run on macOS with the driver installed:
//   clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_icb_copy tools/test_metal_icb_copy.m
//   ./test_metal_icb_copy
// Exit: 0 all checks passed, 1 a check failed, 2 setup/command-buffer failure.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

enum { Render, Groups, Threads };
enum { Direct, Copy, Reset, LateSource, LateCopyDestination, LateResetDestination, Chain, CaseCount };
static const char *g_mode[] = { "render", "compute_groups", "compute_threads" };
static const char *g_case[] = { "direct", "copy_execute", "reset_execute", "late_source",
                              "late_copy_destination", "late_reset_destination", "copy_reset_copy" };
static int g_fail;

static void require(BOOL ok, NSString *what) {
    if (ok) return;
    fprintf(stderr, "FAIL setup: %s\n", what.UTF8String ?: "unknown");
    exit(2);
}

static void commit(id<MTLCommandBuffer> c) {
    [c commit]; [c waitUntilCompleted];
    require(c.status == MTLCommandBufferStatusCompleted, c.error.description ?: @"command buffer incomplete");
}

static id<MTLBuffer> word(id<MTLDevice> d, uint32_t value) {
    id<MTLBuffer> b = [d newBufferWithLength:256 options:MTLResourceStorageModeShared];
    require(b != nil && b.contents != NULL, @"shared buffer");
    ((uint32_t *)b.contents)[0] = value;
    return b;
}

static id<MTLIndirectCommandBuffer> makeICB(id<MTLDevice> d, int mode) {
    MTLIndirectCommandBufferDescriptor *desc = [MTLIndirectCommandBufferDescriptor new];
    desc.commandTypes = mode == Render ? MTLIndirectCommandTypeDraw :
        mode == Groups ? MTLIndirectCommandTypeConcurrentDispatch : MTLIndirectCommandTypeConcurrentDispatchThreads;
    desc.inheritPipelineState = NO; desc.inheritBuffers = NO;
    if (mode == Render) desc.maxFragmentBufferBindCount = 1;
    else desc.maxKernelBufferBindCount = 2;
    id<MTLIndirectCommandBuffer> b = [d newIndirectCommandBufferWithDescriptor:desc maxCommandCount:4 options:0];
    require(b != nil, @"indirect command buffer");
    [b resetWithRange:NSMakeRange(0, 4)];
    return b;
}

static void record(id<MTLIndirectCommandBuffer> b, NSUInteger slot, int mode, id ps,
                   id<MTLBuffer> value, id<MTLBuffer> out) {
    if (mode == Render) {
        id<MTLIndirectRenderCommand> e = [b indirectRenderCommandAtIndex:slot];
        [e reset]; [e setRenderPipelineState:ps];
        [e setFragmentBuffer:value offset:0 atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1 baseInstance:0];
    } else {
        id<MTLIndirectComputeCommand> e = [b indirectComputeCommandAtIndex:slot];
        [e reset]; [e setComputePipelineState:ps];
        [e setKernelBuffer:value offset:0 atIndex:0]; [e setKernelBuffer:out offset:0 atIndex:1];
        if (mode == Groups)
            [e concurrentDispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        else
            [e concurrentDispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    }
}

static void execute(id<MTLCommandBuffer> c, id<MTLIndirectCommandBuffer> b, NSUInteger slot,
                    int mode, id ps, id<MTLTexture> target, NSArray *inputs, id<MTLBuffer> out) {
    if (mode == Render) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(99.0 / 255.0, 0, 0, 1);
        id<MTLRenderCommandEncoder> e = [c renderCommandEncoderWithDescriptor:pass];
        require(e != nil, @"render encoder");
        [e setRenderPipelineState:ps];
        for (id<MTLBuffer> input in inputs) [e useResource:input usage:MTLResourceUsageRead];
        [e executeCommandsInBuffer:b withRange:NSMakeRange(slot, 1)];
        [e endEncoding];
    } else {
        id<MTLComputeCommandEncoder> e = [c computeCommandEncoder];
        require(e != nil, @"compute encoder");
        [e setComputePipelineState:ps];
        for (id<MTLBuffer> input in inputs) [e useResource:input usage:MTLResourceUsageRead];
        [e useResource:out usage:MTLResourceUsageWrite];
        [e executeCommandsInBuffer:b withRange:NSMakeRange(slot, 1)];
        [e endEncoding];
    }
}

static void test(id<MTLDevice> d, id<MTLCommandQueue> q, id ps, int mode, int which) {
    id<MTLBuffer> old = word(d, 23), source = word(d, 61), late = word(d, 173), out = word(d, 99);
    id<MTLIndirectCommandBuffer> src = makeICB(d, mode), dst = makeICB(d, mode);
    record(src, 1, mode, ps, source, out); record(dst, 2, mode, ps, old, out);
    id<MTLTexture> target = nil;
    if (mode == Render) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:1 height:1 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageRenderTarget;
        target = [d newTextureWithDescriptor:td]; require(target != nil, @"render target");
    }
    id<MTLCommandBuffer> c = [q commandBuffer]; require(c != nil, @"command buffer");
    if (which != Direct) {
        id<MTLBlitCommandEncoder> e = [c blitCommandEncoder]; require(e != nil, @"blit encoder");
        if (which == Reset || which == LateResetDestination)
            [e resetCommandsInBuffer:dst withRange:NSMakeRange(2, 1)];
        else {
            [e copyIndirectCommandBuffer:src sourceRange:NSMakeRange(1, 1) destination:dst destinationIndex:2];
            if (which == Chain) {
                [e resetCommandsInBuffer:src withRange:NSMakeRange(1, 1)];
                [e copyIndirectCommandBuffer:dst sourceRange:NSMakeRange(2, 1) destination:src destinationIndex:1];
            }
        }
        [e endEncoding];
    }
    // CPU writes before commit cannot defeat a GPU copy/reset that overwrites these slots.
    if (which == LateCopyDestination || which == LateResetDestination)
        record(dst, 2, mode, ps, late, out);
    execute(c, which == Chain ? src : dst, which == Chain ? 1 : 2, mode, ps, target, @[old, source, late], out);
    // Change the command itself after execute was encoded, not the contents of its input buffer.
    if (which == LateSource) record(src, 1, mode, ps, late, out);
    if (mode == Render) {
        id<MTLBlitCommandEncoder> e = [c blitCommandEncoder]; require(e != nil, @"readback encoder");
        [e copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(1, 1, 1) toBuffer:out destinationOffset:0
           destinationBytesPerRow:256 destinationBytesPerImage:256];
        [e endEncoding];
    }
    commit(c);
    uint32_t got = mode == Render ? ((uint8_t *)out.contents)[0] : ((uint32_t *)out.contents)[0];
    uint32_t want = which == Direct ? 23 : which == Reset || which == LateResetDestination ? 99 : which == LateSource ? 173 : 61;
    printf("%s %s/%s got=%u want=%u\n", got == want ? "PASS" : "FAIL", g_mode[mode], g_case[which], got, want);
    if (got != want) g_fail++;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice(); require(d != nil, @"Metal device");
        printf("device: %s\n", d.name.UTF8String);
        id<MTLCommandQueue> q = [d newCommandQueue]; require(q != nil, @"command queue");
        NSError *err = nil;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void k(constant uint *v [[buffer(0)]], device uint *o [[buffer(1)]]) { o[0] = v[0]; }\n"
            "struct V { float4 p [[position]]; };\n"
            "vertex V v(uint i [[vertex_id]]) {\n"
            "  float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; V o; o.p = float4(p[i],0,1); return o;\n}\n"
            "fragment float4 f(constant uint *v [[buffer(0)]]) { return float4(float(v[0])/255.0f,0,0,1); }\n";
        id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
        require(lib != nil, err.description ?: @"library");
        MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new];
        cd.computeFunction = [lib newFunctionWithName:@"k"]; cd.supportIndirectCommandBuffers = YES;
        id<MTLComputePipelineState> cps = [d newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionNone reflection:nil error:&err];
        require(cps != nil, err.description ?: @"compute pipeline");
        MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"v"]; rd.fragmentFunction = [lib newFunctionWithName:@"f"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; rd.supportIndirectCommandBuffers = YES;
        id<MTLRenderPipelineState> rps = [d newRenderPipelineStateWithDescriptor:rd error:&err];
        require(rps != nil, err.description ?: @"render pipeline");
        for (int mode = Render; mode <= Threads; mode++)
            for (int which = Direct; which < CaseCount; which++)
                @autoreleasepool { test(d, q, mode == Render ? (id)rps : (id)cps, mode, which); }
        printf("%s: %d failure(s)\n", g_fail ? "FAIL" : "PASS", g_fail);
    }
    return g_fail ? 1 : 0;
}
