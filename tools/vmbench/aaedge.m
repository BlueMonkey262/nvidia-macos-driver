// aaedge: does the driver anti-alias the edge of a squircle?
// Counts pixels whose alpha is strictly between 0 and 255.
//   1 shader coverage (SDF), BGRA8, 1 sample, smooth expected
//   2 geometry edge, BGRA8, 4x MSAA + resolve, smooth expected
//   3 shader coverage, A8Unorm, smooth expected
//   4 geometry edge, BGRA8, 1 sample: the control, jagged expected (zero partial pixels)
// usage: aaedge
// build: clang -fobjc-arc -O2 -Wall -o aaedge aaedge.m -framework Foundation -framework Metal
// exit: 0 PASS (cases 1-3 have at least 150 partial pixels, case 4 has none);
//   1 FAIL; 2 the shader did not compile
// output: per case, transparent / opaque / in-between counts, then PASS or FAIL.
//   The sample-count line is what the device claims to support.
// permission: none
// cannot show: what WindowServer or the Dock does. This is an offscreen render
//   into a private texture. A pass here leaves a jagged Dock icon unexplained.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VO { float4 pos [[position]]; float2 p; };\n"
"constant int N = 96; constant float K = 5.0;\n"
"static float2 sq(int i) { float a = 6.2831853 * float(i % N) / float(N); float c = cos(a), s = sin(a);\n"
"  return float2(sign(c) * pow(fabs(c), 2.0 / K), sign(s) * pow(fabs(s), 2.0 / K)) * 0.8; }\n"
"vertex VO vfan(uint vid [[vertex_id]]) { uint t = vid / 3, k = vid % 3; float2 p = k == 0 ? float2(0) : sq(int(t + (k == 2 ? 1 : 0)));\n"
"  VO o; o.pos = float4(p, 0, 1); o.p = p; return o; }\n"
"vertex VO vquad(uint vid [[vertex_id]]) { float2 q[6] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,-1), float2(1,1), float2(-1,1)};\n"
"  VO o; o.pos = float4(q[vid], 0, 1); o.p = q[vid]; return o; }\n"
"fragment float4 fsolid(VO i [[stage_in]]) { return float4(1); }\n"
"fragment float4 fsdf(VO i [[stage_in]]) { float2 a = fabs(i.p) / 0.8; float f = pow(a.x, K) + pow(a.y, K); float d = (pow(f, 1.0 / K) - 1.0) * 0.8 * 64.0;\n"
"  float al = clamp(0.5 - d, 0.0, 1.0); return float4(al, al, al, al); }\n";
static int count_edge(const uint8_t *b, int w, int h, size_t stride, int bpp, int ach, int *zero, int *full)
{
    int mid = 0; *zero = 0; *full = 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int a = b[y * stride + x * bpp + ach]; if (a == 0) (*zero)++; else if (a == 255) (*full)++; else mid++; }
    return mid;
}
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); printf("device %s\n", dev.name.UTF8String);
    printf("sample counts supported:"); for (int n = 1; n <= 8; n *= 2) printf(" %d=%s", n, [dev supportsTextureSampleCount:n] ? "yes" : "no"); printf("\n");
    NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    if (!lib) { printf("shader compile failed: %s\n", err.localizedDescription.UTF8String); return 2; }
    id<MTLCommandQueue> q = [dev newCommandQueue]; const int W = 128;
    struct { const char *name; BOOL msaa; BOOL sdf; MTLPixelFormat fmt; } cases[] = {
        { "1 shader-coverage SDF, BGRA8, 1 sample", NO, YES, MTLPixelFormatBGRA8Unorm },
        { "2 geometry edge, BGRA8, 4x MSAA + resolve", YES, NO, MTLPixelFormatBGRA8Unorm },
        { "3 shader-coverage SDF, A8Unorm target", NO, YES, MTLPixelFormatA8Unorm },
        { "4 geometry edge, BGRA8, 1 sample (control: jagged expected)", NO, NO, MTLPixelFormatBGRA8Unorm } };
    int bad = 0;
    for (int c = 0; c < 4; c++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:cases[c].fmt width:W height:W mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> resolve = [dev newTextureWithDescriptor:td], msaa = nil;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        if (cases[c].msaa) {
            MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:cases[c].fmt width:W height:W mipmapped:NO];
            md.textureType = MTLTextureType2DMultisample; md.sampleCount = 4; md.usage = MTLTextureUsageRenderTarget; md.storageMode = MTLStorageModePrivate;
            msaa = [dev newTextureWithDescriptor:md]; if (!msaa) { printf("case %s: cannot create 4x MSAA texture\n", cases[c].name); bad++; continue; }
            rp.colorAttachments[0].texture = msaa; rp.colorAttachments[0].resolveTexture = resolve; rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        } else { rp.colorAttachments[0].texture = resolve; rp.colorAttachments[0].storeAction = MTLStoreActionStore; }
        rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:cases[c].sdf ? @"vquad" : @"vfan"]; pd.fragmentFunction = [lib newFunctionWithName:cases[c].sdf ? @"fsdf" : @"fsolid"];
        pd.colorAttachments[0].pixelFormat = cases[c].fmt; pd.rasterSampleCount = cases[c].msaa ? 4 : 1;
        if (cases[c].sdf) { pd.colorAttachments[0].blendingEnabled = NO; }
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) { printf("case %s: pipeline failed: %s\n", cases[c].name, err.localizedDescription.UTF8String); bad++; continue; }
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:ps]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:cases[c].sdf ? 6 : 96 * 3]; [e endEncoding];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl synchronizeResource:resolve]; [bl endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        int bpp = cases[c].fmt == MTLPixelFormatA8Unorm ? 1 : 4, ach = bpp == 1 ? 0 : 3; size_t stride = (size_t)W * bpp; uint8_t *buf = malloc(stride * W);
        [resolve getBytes:buf bytesPerRow:stride fromRegion:MTLRegionMake2D(0, 0, W, W) mipmapLevel:0];
        int z, f, mid = count_edge(buf, W, W, stride, bpp, ach, &z, &f);
        BOOL wantSmooth = c < 3; BOOL ok = wantSmooth ? mid >= 150 : mid == 0;
        printf("%-62s transparent %5d  opaque %5d  in-between %4d  -> %s\n", cases[c].name, z, f, mid, ok ? "ok" : (wantSmooth ? "JAGGED EDGE (no anti-aliasing)" : "control not jagged?"));
        if (!ok) bad++; free(buf);
    }
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad ? 1 : 0;
} }
