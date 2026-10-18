// minify: shrink a smooth 1024 px squircle to 128 px and compare with a CPU box filter.
// usage: minify [mps_only]
//   mps_only 0 runs MPSImageLanczosScale only, 1 runs MPSImageBilinearScale only.
//   Omit it to run every sampler and both MPS scalers.
// build: clang -fobjc-arc -O2 -Wall -o minify minify.m -framework Foundation -framework Metal -framework MetalPerformanceShaders
// exit: 0 PASS; 1 a case that should be smooth was too far from the box reference; 2 the shader did not compile
// output: mean absolute error of the alpha channel against the box filter, and how
//   many pixels landed strictly between 0 and 255. Smooth cases must be under 3.0
//   mean abs error. The two "not expected smooth" rows (no mips, and nearest of
//   level 0) are printed and not failed. generateMipmaps level 3 is reported and
//   not part of the pass/fail. An MPS abort (the Lanczos imageblock fault) kills
//   the process before PASS/FAIL; that abort is itself the result.
// permission: none
// cannot show: the Dock, Core Image, or WindowServer's resample shader. Those are
//   cilanczos, dscale, and skylib. A pass here means this process's sampler and
//   MPS path, offscreen.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#include <math.h>
static NSString *msl = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VO { float4 pos [[position]]; float2 p; };\n"
"vertex VO vquad(uint vid [[vertex_id]]) { float2 q[6] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,-1), float2(1,1), float2(-1,1)};\n"
"  VO o; o.pos = float4(q[vid], 0, 1); o.p = q[vid]; return o; }\n"
"fragment float4 fsdf(VO i [[stage_in]], constant float &px [[buffer(0)]]) { float2 a = fabs(i.p) / 0.8; float f = pow(a.x, 5.0) + pow(a.y, 5.0); float d = (pow(f, 0.2) - 1.0) * 0.8 * px * 0.5;\n"
"  float al = clamp(0.5 - d, 0.0, 1.0); return float4(al, al, al, al); }\n"
"fragment float4 fsamp(VO i [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, float2(i.p.x * 0.5 + 0.5, 0.5 - i.p.y * 0.5)); }\n"
"fragment float4 flvl(VO i [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant float &lv [[buffer(0)]]) { return t.sample(s, float2(i.p.x * 0.5 + 0.5, 0.5 - i.p.y * 0.5), level(lv)); }\n";
static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLLibrary> lib;
static id<MTLRenderPipelineState> pso(NSString *v, NSString *f) { MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [lib newFunctionWithName:v]; d.fragmentFunction = [lib newFunctionWithName:f]; d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; NSError *e = nil; id r = [dev newRenderPipelineStateWithDescriptor:d error:&e]; if (!r) printf("pipeline %s: %s\n", f.UTF8String, e.localizedDescription.UTF8String); return r; }
static void readback(id<MTLCommandBuffer> cb, id<MTLTexture> t) { id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder]; [b synchronizeResource:t]; [b endEncoding]; }
int main(int argc, char **argv) { @autoreleasepool {
    int only = argc > 1 ? atoi(argv[1]) : -1;
    dev = MTLCreateSystemDefaultDevice(); printf("device %s\n", dev.name.UTF8String);
    NSError *err = nil; lib = [dev newLibraryWithSource:msl options:nil error:&err]; if (!lib) { printf("shader: %s\n", err.localizedDescription.UTF8String); return 2; }
    q = [dev newCommandQueue]; const int S = 1024, D = 128;
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:S height:S mipmapped:YES];
    sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; sd.storageMode = MTLStorageModeManaged;
    id<MTLTexture> srcT = [dev newTextureWithDescriptor:sd]; printf("source mip levels: %lu\n", (unsigned long)srcT.mipmapLevelCount);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = srcT; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:pso(@"vquad", @"fsdf")];
    float px = S; [e setFragmentBytes:&px length:4 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [e endEncoding];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl generateMipmapsForTexture:srcT]; [bl synchronizeResource:srcT]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
    // CPU reference: box filter of level 0 (read back) down to D x D
    uint8_t *l0 = malloc((size_t)S * S * 4); [srcT getBytes:l0 bytesPerRow:S * 4 fromRegion:MTLRegionMake2D(0, 0, S, S) mipmapLevel:0];
    float *ref = malloc(D * D * sizeof(float)); int f = S / D;
    for (int y = 0; y < D; y++) for (int x = 0; x < D; x++) { float s = 0; for (int j = 0; j < f; j++) for (int i = 0; i < f; i++) s += l0[((y * f + j) * S + x * f + i) * 4 + 3]; ref[y * D + x] = s / (f * f); }
    int refmid = 0; for (int i = 0; i < D * D; i++) if (ref[i] > 0.5f && ref[i] < 254.5f) refmid++;
    printf("reference (CPU box filter): %d in-between alpha values of %d\n", refmid, D * D);
    // GPU generated mip level 3 (128 px) vs box reference
    uint8_t *m3 = malloc((size_t)D * D * 4); [srcT getBytes:m3 bytesPerRow:D * 4 fromRegion:MTLRegionMake2D(0, 0, D, D) mipmapLevel:3];
    { double se = 0; int mid = 0; for (int i = 0; i < D * D; i++) { double d = m3[i * 4 + 3] - ref[i]; se += fabs(d); if (m3[i*4+3] > 0 && m3[i*4+3] < 255) mid++; } printf("%-58s mean abs err %6.2f  in-between %5d\n", "generateMipmaps level 3 (128 px) vs box reference", se / (D * D), mid); }
    struct { const char *name; MTLSamplerMinMagFilter minf, magf; MTLSamplerMipFilter mip; float level; } v[] = {
        { "sample: min linear, mip linear (trilinear)", MTLSamplerMinMagFilterLinear, MTLSamplerMinMagFilterLinear, MTLSamplerMipFilterLinear, -1 },
        { "sample: min linear, mip nearest", MTLSamplerMinMagFilterLinear, MTLSamplerMinMagFilterLinear, MTLSamplerMipFilterNearest, -1 },
        { "sample: min linear, no mips (bilinear of level 0)", MTLSamplerMinMagFilterLinear, MTLSamplerMinMagFilterLinear, MTLSamplerMipFilterNotMipmapped, -1 },
        { "sample: min nearest, no mips", MTLSamplerMinMagFilterNearest, MTLSamplerMinMagFilterNearest, MTLSamplerMipFilterNotMipmapped, -1 },
        { "level(3) explicit, linear", MTLSamplerMinMagFilterLinear, MTLSamplerMinMagFilterLinear, MTLSamplerMipFilterNearest, 3 },
        { "level(0) explicit, nearest", MTLSamplerMinMagFilterNearest, MTLSamplerMinMagFilterNearest, MTLSamplerMipFilterNearest, 0 } };
    int bad = 0;
    for (int c = 0; c < 6; c++) {
        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:D height:D mipmapped:NO]; dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModeManaged;
        id<MTLTexture> dst = [dev newTextureWithDescriptor:dd]; MTLSamplerDescriptor *sdsc = [MTLSamplerDescriptor new]; sdsc.minFilter = v[c].minf; sdsc.magFilter = v[c].magf; sdsc.mipFilter = v[c].mip; sdsc.maxAnisotropy = 1;
        id<MTLSamplerState> ss = [dev newSamplerStateWithDescriptor:sdsc];
        MTLRenderPassDescriptor *r2 = [MTLRenderPassDescriptor renderPassDescriptor]; r2.colorAttachments[0].texture = dst; r2.colorAttachments[0].loadAction = MTLLoadActionClear; r2.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0); r2.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> c2 = [q commandBuffer]; id<MTLRenderCommandEncoder> e2 = [c2 renderCommandEncoderWithDescriptor:r2];
        [e2 setRenderPipelineState:pso(@"vquad", v[c].level >= 0 ? @"flvl" : @"fsamp")]; [e2 setFragmentTexture:srcT atIndex:0]; [e2 setFragmentSamplerState:ss atIndex:0];
        if (v[c].level >= 0) { float lv = v[c].level; [e2 setFragmentBytes:&lv length:4 atIndex:0]; }
        [e2 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [e2 endEncoding]; readback(c2, dst); [c2 commit]; [c2 waitUntilCompleted];
        uint8_t *o = malloc((size_t)D * D * 4); [dst getBytes:o bytesPerRow:D * 4 fromRegion:MTLRegionMake2D(0, 0, D, D) mipmapLevel:0];
        double se = 0; int mid = 0; for (int i = 0; i < D * D; i++) { se += fabs(o[i * 4 + 3] - ref[i]); if (o[i*4+3] > 0 && o[i*4+3] < 255) mid++; }
        double mae = se / (D * D); int smooth_expected = c < 2 || c == 4; BOOL ok = smooth_expected ? mae < 3.0 : YES;
        printf("%-58s mean abs err %6.2f  in-between %5d  %s\n", v[c].name, mae, mid, smooth_expected ? (ok ? "ok" : "TOO FAR FROM THE SMOOTH REFERENCE") : "(not expected smooth)");
        if (!ok) bad++; free(o);
    }

    { // MPS scalers (what Core Image / Core Graphics style scaling uses)
        struct { const char *name; int kind; } m[] = { { "MPSImageLanczosScale", 0 }, { "MPSImageBilinearScale", 1 } };
        for (int c = 0; c < 2; c++) {
            if (only >= 0 && c != only) continue;
            MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:D height:D mipmapped:NO]; dd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModeManaged;
            id<MTLTexture> dst = [dev newTextureWithDescriptor:dd];
            MPSImageScale *k = m[c].kind == 0 ? [[MPSImageLanczosScale alloc] initWithDevice:dev] : [[MPSImageBilinearScale alloc] initWithDevice:dev];
            id<MTLCommandBuffer> c3 = [q commandBuffer]; [k encodeToCommandBuffer:c3 sourceTexture:srcT destinationTexture:dst]; readback(c3, dst); [c3 commit]; [c3 waitUntilCompleted];
            uint8_t *o = malloc((size_t)D * D * 4); [dst getBytes:o bytesPerRow:D * 4 fromRegion:MTLRegionMake2D(0, 0, D, D) mipmapLevel:0];
            double se = 0; int mid = 0, nz = 0; for (int i = 0; i < D * D; i++) { se += fabs(o[i * 4 + 3] - ref[i]); if (o[i*4+3] > 0 && o[i*4+3] < 255) mid++; if (o[i*4+3]) nz++; }
            double mae = se / (D * D); BOOL ok = mae < 3.0 && nz > 5000;
            printf("%-58s mean abs err %6.2f  in-between %5d  nonzero %5d  %s\n", m[c].name, mae, mid, nz, ok ? "ok" : "WRONG vs the smooth reference");
            if (!ok) bad++; free(o);
        }
    }
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad ? 1 : 0;
} }
