// Nil unbind: after set*Buffer:/set*Texture: nil (and the range forms), a later draw/dispatch must
// not see the previous binding. Old driver left the slot stale; new one clears it (buffers -> zeros).
// Build and run on the macOS machine with the driver installed:
//   clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_nil_unbind tools/test_metal_nil_unbind.m
//   ./test_metal_nil_unbind
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

static int g_fail;

static void expect_u32(const char *name, uint32_t got, uint32_t want) {
    if (got == want) { printf("PASS %s got=%u\n", name, got); return; }
    printf("FAIL %s got=%u want=%u\n", name, got, want);
    g_fail++;
}

static void commit(id<MTLCommandBuffer> c) {
    [c commit];
    [c waitUntilCompleted];
    if (c.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "FAIL command buffer: %s\n", c.error.description.UTF8String ?: "incomplete");
        exit(2);
    }
}

static id<MTLLibrary> makeLib(id<MTLDevice> d) {
    NSError *err = nil;
    NSString *src =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "kernel void kCopyBuf(device uint *in [[buffer(0)]], device uint *out [[buffer(1)]]) {\n"
         "  out[0] = in[0];\n"
         "}\n"
         "kernel void kCopyTex(texture2d<float, access::read> tex [[texture(0)]],\n"
         "                     device uint *out [[buffer(0)]]) {\n"
         "  float4 c = tex.read(uint2(0, 0));\n"
         "  out[0] = uint(c.r * 255.0f + 0.5f);\n"
         "}\n"
         "struct VOut { float4 pos [[position]]; };\n"
         "vertex VOut vMain(uint vid [[vertex_id]]) {\n"
         "  float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
         "  VOut o; o.pos = float4(p[vid], 0, 1); return o;\n"
         "}\n"
         "fragment float4 fBuf(constant uint *u [[buffer(0)]]) {\n"
         "  float v = float(u[0]) / 255.0f;\n"
         "  return float4(v, 0, 0, 1);\n"
         "}\n"
         "fragment float4 fTex(texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {\n"
         "  return tex.sample(s, float2(0.5, 0.5));\n"
         "}\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) {
        fprintf(stderr, "FAIL library: %s\n", err.description.UTF8String ?: "?");
        exit(2);
    }
    return lib;
}

static uint32_t readbackU32(id<MTLBuffer> b) { return ((const uint32_t *)b.contents)[0]; }

static uint8_t readPixelR(id<MTLTexture> t) {
    uint8_t px[4] = {0};
    [t getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    return px[0];
}

static void testComputeBuffer(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib, BOOL range) {
    NSError *err = nil;
    id<MTLFunction> fn = [lib newFunctionWithName:@"kCopyBuf"];
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:fn error:&err];
    if (!ps) { fprintf(stderr, "FAIL cps: %s\n", err.description.UTF8String ?: "?"); exit(2); }

    const uint32_t sentinel = 0xA1B2C3D4u;
    id<MTLBuffer> src = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> outBound = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> outNil = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    ((uint32_t *)src.contents)[0] = sentinel;
    memset(outBound.contents, 0x5a, 16);
    memset(outNil.contents, 0x5a, 16);

    id<MTLCommandBuffer> c = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [c computeCommandEncoder];
    [e setComputePipelineState:ps];
    [e setBuffer:src offset:0 atIndex:0];
    [e setBuffer:outBound offset:0 atIndex:1];
    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    // nil must clear slot 0; a second dispatch must copy zeros, not the sentinel
    if (range) {
        id<MTLBuffer> nils[1] = { nil };
        NSUInteger offs[1] = { 0 };
        [e setBuffers:nils offsets:offs withRange:NSMakeRange(0, 1)];
    } else {
        [e setBuffer:nil offset:0 atIndex:0];
    }
    [e setBuffer:outNil offset:0 atIndex:1];
    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [e endEncoding];
    commit(c);

    if (readbackU32(outBound) != sentinel) {
        printf("FAIL %s setup bound got=%u want=%u\n", range ? "compute_setBuffers" : "compute_setBuffer",
               readbackU32(outBound), sentinel);
        g_fail++;
        return;
    }
    const char *name = range ? "compute_setBuffers_nil" : "compute_setBuffer_nil";
    expect_u32(name, readbackU32(outNil), 0);
}

static void testComputeTexture(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib, BOOL range) {
    NSError *err = nil;
    id<MTLFunction> fn = [lib newFunctionWithName:@"kCopyTex"];
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:fn error:&err];
    if (!ps) { fprintf(stderr, "FAIL cps tex: %s\n", err.description.UTF8String ?: "?"); exit(2); }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [d newTextureWithDescriptor:td];
    uint8_t red[4] = { 200, 0, 0, 255 };
    [tex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:red bytesPerRow:4];
    id<MTLBuffer> outBound = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> outNil = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    memset(outBound.contents, 0x5a, 16);
    memset(outNil.contents, 0x5a, 16);

    id<MTLCommandBuffer> c = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [c computeCommandEncoder];
    [e setComputePipelineState:ps];
    [e setTexture:tex atIndex:0];
    [e setBuffer:outBound offset:0 atIndex:0];
    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    if (range) {
        id<MTLTexture> nils[1] = { nil };
        [e setTextures:nils withRange:NSMakeRange(0, 1)];
    } else {
        [e setTexture:nil atIndex:0];
    }
    [e setBuffer:outNil offset:0 atIndex:0];
    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [e endEncoding];
    commit(c);

    if (readbackU32(outBound) < 180) {
        printf("FAIL %s setup bound got=%u\n", range ? "compute_setTextures" : "compute_setTexture",
               readbackU32(outBound));
        g_fail++;
        return;
    }
    const char *name = range ? "compute_setTextures_nil" : "compute_setTexture_nil";
    expect_u32(name, readbackU32(outNil), 0);
}

static id<MTLRenderPipelineState> makeRPS(id<MTLDevice> d, id<MTLLibrary> lib, NSString *frag) {
    NSError *err = nil;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vMain"];
    pd.fragmentFunction = [lib newFunctionWithName:frag];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { fprintf(stderr, "FAIL rps %s: %s\n", frag.UTF8String, err.description.UTF8String ?: "?"); exit(2); }
    return ps;
}

static id<MTLTexture> makeTarget(id<MTLDevice> d) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    return [d newTextureWithDescriptor:td];
}

static void drawOnce(id<MTLCommandBuffer> c, id<MTLTexture> dst, id<MTLRenderPipelineState> ps,
                     void (^bind)(id<MTLRenderCommandEncoder> e)) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> e = [c renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps];
    bind(e);
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

static void testRenderBuffer(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib, BOOL range) {
    id<MTLRenderPipelineState> ps = makeRPS(d, lib, @"fBuf");
    id<MTLTexture> dst = makeTarget(d);
    const uint32_t sentinel = 255;
    id<MTLBuffer> src = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    ((uint32_t *)src.contents)[0] = sentinel;

    // bound: expect red ~255
    {
        id<MTLCommandBuffer> c = [q commandBuffer];
        drawOnce(c, dst, ps, ^(id<MTLRenderCommandEncoder> e) {
            [e setFragmentBuffer:src offset:0 atIndex:0];
        });
        commit(c);
        uint8_t r = readPixelR(dst);
        if (r < 250) {
            printf("FAIL render_buffer_bound setup got R=%u (need ~255)\n", r);
            g_fail++;
            return;
        }
    }
    // nil then draw: expect R=0 (stale binding would still show ~255)
    {
        id<MTLCommandBuffer> c = [q commandBuffer];
        drawOnce(c, dst, ps, ^(id<MTLRenderCommandEncoder> e) {
            [e setFragmentBuffer:src offset:0 atIndex:0];
            if (range) {
                id<MTLBuffer> nils[1] = { nil };
                NSUInteger offs[1] = { 0 };
                [e setFragmentBuffers:nils offsets:offs withRange:NSMakeRange(0, 1)];
            } else {
                [e setFragmentBuffer:nil offset:0 atIndex:0];
            }
        });
        commit(c);
        const char *name = range ? "render_setFragmentBuffers_nil" : "render_setFragmentBuffer_nil";
        expect_u32(name, readPixelR(dst), 0);
    }
}

static void testRenderTexture(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib, BOOL range) {
    id<MTLRenderPipelineState> ps = makeRPS(d, lib, @"fTex");
    id<MTLTexture> dst = makeTarget(d);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [d newTextureWithDescriptor:td];
    uint8_t red[4] = { 200, 0, 0, 255 };
    [tex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:red bytesPerRow:4];
    id<MTLSamplerState> samp = [d newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];

    {
        id<MTLCommandBuffer> c = [q commandBuffer];
        drawOnce(c, dst, ps, ^(id<MTLRenderCommandEncoder> e) {
            [e setFragmentTexture:tex atIndex:0];
            [e setFragmentSamplerState:samp atIndex:0];
        });
        commit(c);
        uint8_t r = readPixelR(dst);
        if (r < 180) {
            printf("FAIL render_texture_bound setup got R=%u (need ~200)\n", r);
            g_fail++;
            return;
        }
    }
    {
        id<MTLCommandBuffer> c = [q commandBuffer];
        drawOnce(c, dst, ps, ^(id<MTLRenderCommandEncoder> e) {
            [e setFragmentTexture:tex atIndex:0];
            [e setFragmentSamplerState:samp atIndex:0];
            if (range) {
                id<MTLTexture> nils[1] = { nil };
                [e setFragmentTextures:nils withRange:NSMakeRange(0, 1)];
            } else {
                [e setFragmentTexture:nil atIndex:0];
            }
        });
        commit(c);
        const char *name = range ? "render_setFragmentTextures_nil" : "render_setFragmentTexture_nil";
        expect_u32(name, readPixelR(dst), 0);
    }
}

static void testRenderVertexBuffer(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLLibrary> lib) {
    // Vertex-stage unbind: fragment still reads buffer(0); binding on vertex must not leave fragment stale.
    // Exercise setVertexBuffer:nil clearing the encoder table used by later draws via a second CB that
    // binds on fragment only after a vertex nil (covers the shared clear helper path for vertex).
    NSError *err = nil;
    NSString *src =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct VOut { float4 pos [[position]]; uint v; };\n"
         "vertex VOut vPull(uint vid [[vertex_id]], constant uint *u [[buffer(0)]]) {\n"
         "  float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
         "  VOut o; o.pos = float4(p[vid], 0, 1); o.v = u[0]; return o;\n"
         "}\n"
         "fragment float4 fPull(VOut in [[stage_in]]) {\n"
         "  float v = float(in.v) / 255.0f;\n"
         "  return float4(v, 0, 0, 1);\n"
         "}\n";
    id<MTLLibrary> vlib = [d newLibraryWithSource:src options:nil error:&err];
    if (!vlib) { fprintf(stderr, "FAIL vlib: %s\n", err.description.UTF8String ?: "?"); exit(2); }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [vlib newFunctionWithName:@"vPull"];
    pd.fragmentFunction = [vlib newFunctionWithName:@"fPull"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { fprintf(stderr, "FAIL vrps: %s\n", err.description.UTF8String ?: "?"); exit(2); }
    id<MTLTexture> dst = makeTarget(d);
    id<MTLBuffer> srcBuf = [d newBufferWithLength:16 options:MTLResourceStorageModeShared];
    ((uint32_t *)srcBuf.contents)[0] = 255;

    {
        id<MTLCommandBuffer> c = [q commandBuffer];
        drawOnce(c, dst, ps, ^(id<MTLRenderCommandEncoder> e) {
            [e setVertexBuffer:srcBuf offset:0 atIndex:0];
            [e setVertexBuffer:nil offset:0 atIndex:0];
        });
        commit(c);
        expect_u32("render_setVertexBuffer_nil", readPixelR(dst), 0);
    }
    {
        id<MTLCommandBuffer> c = [q commandBuffer];
        drawOnce(c, dst, ps, ^(id<MTLRenderCommandEncoder> e) {
            [e setVertexBuffer:srcBuf offset:0 atIndex:0];
            id<MTLBuffer> nils[1] = { nil };
            NSUInteger offs[1] = { 0 };
            [e setVertexBuffers:nils offsets:offs withRange:NSMakeRange(0, 1)];
        });
        commit(c);
        expect_u32("render_setVertexBuffers_nil", readPixelR(dst), 0);
    }
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) { fprintf(stderr, "FAIL no Metal device\n"); return 2; }
        id<MTLCommandQueue> q = [d newCommandQueue];
        if (!q) { fprintf(stderr, "FAIL no queue\n"); return 2; }
        printf("DEVICE %s\n", d.name.UTF8String);
        id<MTLLibrary> lib = makeLib(d);

        testComputeBuffer(d, q, lib, NO);
        testComputeBuffer(d, q, lib, YES);
        testComputeTexture(d, q, lib, NO);
        testComputeTexture(d, q, lib, YES);
        testRenderBuffer(d, q, lib, NO);
        testRenderBuffer(d, q, lib, YES);
        testRenderTexture(d, q, lib, NO);
        testRenderTexture(d, q, lib, YES);
        testRenderVertexBuffer(d, q, lib);

        printf("RESULT fails=%d\n", g_fail);
        return g_fail ? 1 : 0;
    }
}
