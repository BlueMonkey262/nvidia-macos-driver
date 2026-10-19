// Bind-time sampler LOD clamp overrides (set*SamplerState:lodMinClamp:lodMaxClamp:).
// Builds a mipmapped texture whose levels hold distinct constants, samples with an explicit
// level(), and checks that lodMinClamp forces a blurrier level and lodMaxClamp a sharper one
// in both a render pass and a compute dispatch.
//
// Build and run on the macOS machine with the driver as the default Metal device:
//   clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_lod_clamp tools/test_metal_lod_clamp.m
//   ./test_metal_lod_clamp
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <float.h>
#include <stdio.h>
#include <string.h>

static void fail(NSString *s) { fprintf(stderr, "PROBE_ERROR: %s\n", s.UTF8String); exit(2); }
static void done(id<MTLCommandBuffer> c) {
    if (!c) fail(@"nil command buffer");
    [c commit]; [c waitUntilCompleted];
    if (c.status != MTLCommandBufferStatusCompleted) fail(c.error.description ?: @"command did not complete");
}

enum { kLevels = 3, kTexSize = 8 };
/* Distinct constants per mip (RGBA8Unorm). Nearest mip + level() makes the sample equal the level. */
static const uint8_t kMipR[kLevels] = { 32, 96, 200 };

static id<MTLTexture> make_mips(id<MTLDevice> d) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:kTexSize height:kTexSize
                                                                               mipmapped:YES];
    td.usage = MTLTextureUsageShaderRead;
    td.mipmapLevelCount = kLevels;
    id<MTLTexture> t = [d newTextureWithDescriptor:td];
    if (!t || t.mipmapLevelCount < kLevels) fail(@"mipmapped texture allocation failed");
    for (NSUInteger level = 0; level < kLevels; level++) {
        NSUInteger w = kTexSize >> level; if (w < 1) w = 1; NSUInteger h = w;
        NSMutableData *px = [NSMutableData dataWithLength:w * h * 4];
        uint8_t *p = px.mutableBytes;
        for (NSUInteger i = 0; i < w * h; i++) {
            p[i * 4 + 0] = kMipR[level]; p[i * 4 + 1] = 0; p[i * 4 + 2] = 0; p[i * 4 + 3] = 255;
        }
        [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:level withBytes:p bytesPerRow:w * 4];
    }
    return t;
}

static id<MTLSamplerState> make_sampler(id<MTLDevice> d) {
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterNearest;
    sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.mipFilter = MTLSamplerMipFilterNearest;
    sd.lodMinClamp = 0.0f;
    sd.lodMaxClamp = FLT_MAX;
    id<MTLSamplerState> s = [d newSamplerStateWithDescriptor:sd];
    if (!s) fail(@"sampler allocation failed");
    return s;
}

static void expect_r(const char *tag, uint8_t got, uint8_t want) {
    if (got != want)
        fail([NSString stringWithFormat:@"%s: got R=%u want R=%u (LOD clamp override not applied)",
              tag, (unsigned)got, (unsigned)want]);
    fprintf(stderr, "ok %s R=%u\n", tag, (unsigned)got);
}

static uint8_t sample_render(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> tex,
                             id<MTLSamplerState> samp, BOOL override, float lo, float hi, float level) {
    NSError *err = nil;
    NSString *src =
        @"#include <metal_stdlib>\nusing namespace metal;\n"
        @"struct VOut { float4 pos [[position]]; };\n"
        @"vertex VOut v_main(uint vid [[vertex_id]]) {\n"
        @"  float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
        @"  VOut o; o.pos = float4(p[vid], 0, 1); return o;\n"
        @"}\n"
        @"fragment float4 f_main(VOut in [[stage_in]],\n"
        @"    texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]],\n"
        @"    constant float &lod [[buffer(0)]]) {\n"
        @"  return tex.sample(samp, float2(0.5, 0.5), level(lod));\n"
        @"}\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) fail(err.description ?: @"render library");
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"v_main"];
    pd.fragmentFunction = [lib newFunctionWithName:@"f_main"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) fail(err.description ?: @"render pipeline");

    MTLTextureDescriptor *rt = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:1 height:1 mipmapped:NO];
    rt.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> out = [d newTextureWithDescriptor:rt];
    if (!out) fail(@"render target");

    id<MTLBuffer> lodBuf = [d newBufferWithBytes:&level length:sizeof(level) options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = out;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:ps];
    [enc setFragmentTexture:tex atIndex:0];
    [enc setFragmentBuffer:lodBuf offset:0 atIndex:0];
    if (override) [enc setFragmentSamplerState:samp lodMinClamp:lo lodMaxClamp:hi atIndex:0];
    else [enc setFragmentSamplerState:samp atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    done(cb);

    uint8_t px[4] = {0};
    [out getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    return px[0];
}

static uint8_t sample_compute(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> tex,
                              id<MTLSamplerState> samp, BOOL override, float lo, float hi, float level) {
    NSError *err = nil;
    NSString *src =
        @"#include <metal_stdlib>\nusing namespace metal;\n"
        @"kernel void k_main(texture2d<float> tex [[texture(0)]], sampler samp [[sampler(0)]],\n"
        @"    constant float &lod [[buffer(0)]], device uchar4 *out [[buffer(1)]]) {\n"
        @"  float4 c = tex.sample(samp, float2(0.5, 0.5), level(lod));\n"
        @"  out[0] = uchar4((uchar)round(c.r * 255.0), 0, 0, 255);\n"
        @"}\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) fail(err.description ?: @"compute library");
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_main"] error:&err];
    if (!ps) fail(err.description ?: @"compute pipeline");

    id<MTLBuffer> lodBuf = [d newBufferWithBytes:&level length:sizeof(level) options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [d newBufferWithLength:4 options:MTLResourceStorageModeShared];
    if (!lodBuf || !out) fail(@"compute buffers");
    memset(out.contents, 0, 4);

    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:ps];
    [enc setTexture:tex atIndex:0];
    [enc setBuffer:lodBuf offset:0 atIndex:0];
    [enc setBuffer:out offset:0 atIndex:1];
    if (override) [enc setSamplerState:samp lodMinClamp:lo lodMaxClamp:hi atIndex:0];
    else [enc setSamplerState:samp atIndex:0];
    [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    done(cb);
    return ((const uint8_t *)out.contents)[0];
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) fail(@"no Metal device");
        id<MTLCommandQueue> q = [d newCommandQueue];
        if (!q) fail(@"no queue");
        id<MTLTexture> tex = make_mips(d);
        id<MTLSamplerState> samp = make_sampler(d);

        /* Baseline: explicit level selects that mip with the state's own clamps. */
        expect_r("render baseline level0", sample_render(d, q, tex, samp, NO, 0, 0, 0.f), kMipR[0]);
        expect_r("render baseline level2", sample_render(d, q, tex, samp, NO, 0, 0, 2.f), kMipR[2]);
        expect_r("compute baseline level0", sample_compute(d, q, tex, samp, NO, 0, 0, 0.f), kMipR[0]);
        expect_r("compute baseline level2", sample_compute(d, q, tex, samp, NO, 0, 0, 2.f), kMipR[2]);

        /* lodMinClamp=2 with level(0) must force the blurrier mip (level 2). */
        expect_r("render lodMinClamp->2", sample_render(d, q, tex, samp, YES, 2.f, FLT_MAX, 0.f), kMipR[2]);
        expect_r("compute lodMinClamp->2", sample_compute(d, q, tex, samp, YES, 2.f, FLT_MAX, 0.f), kMipR[2]);

        /* lodMaxClamp=0 with level(2) must force the sharper mip (level 0). */
        expect_r("render lodMaxClamp->0", sample_render(d, q, tex, samp, YES, 0.f, 0.f, 2.f), kMipR[0]);
        expect_r("compute lodMaxClamp->0", sample_compute(d, q, tex, samp, YES, 0.f, 0.f, 2.f), kMipR[0]);

        fprintf(stderr, "PASS lod clamp overrides (render + compute)\n");
        return 0;
    }
}
