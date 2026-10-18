// blendbench: GPU fill-rate of stacked full-screen layers at 1920x1080: opaque, alpha blend, alpha-test (discard), blend+depth test.
// Prints ms per frame and Gpixel/s (wall time with waitUntilCompleted). usage: blendbench [layers [iterations]]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static NSString *msl = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 pos [[position]]; float2 uv; };\n"
"vertex VO vq(uint vid [[vertex_id]], uint iid [[instance_id]]) { float2 q[6] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,-1), float2(1,1), float2(-1,1)}; VO o; o.pos = float4(q[vid], 1.0 - float(iid) * 0.001, 1); o.uv = q[vid] * 0.5 + 0.5; return o; }\n"
"fragment float4 f_opaque(VO i [[stage_in]]) { return float4(i.uv, 0.5, 1.0); }\n"
"fragment float4 f_alpha(VO i [[stage_in]]) { return float4(i.uv, 0.5, 0.25); }\n"
"fragment float4 f_discard(VO i [[stage_in]]) { if (fract(i.uv.x * 40.0) < 0.5) discard_fragment(); return float4(i.uv, 0.5, 1.0); }\n";
int main(int argc, char **argv) { @autoreleasepool {
    int layers = argc > 1 ? atoi(argv[1]) : 40, iters = argc > 2 ? atoi(argv[2]) : 30; const int W = 1920, H = 1080;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); printf("device %s, %d layers of %dx%d, %d frames\n", dev.name.UTF8String, layers, W, H, iters);
    NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err]; if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 2; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate; id<MTLTexture> color = [dev newTextureWithDescriptor:td];
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:H mipmapped:NO]; dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate; id<MTLTexture> depth = [dev newTextureWithDescriptor:dd];
    struct { const char *name; NSString *fs; BOOL blend; BOOL depthTest; } v[] = { { "opaque, no depth", @"f_opaque", NO, NO }, { "opaque, depth test+write", @"f_opaque", NO, YES }, { "alpha blend (src-alpha)", @"f_alpha", YES, NO }, { "alpha blend + depth test (no write)", @"f_alpha", YES, YES }, { "alpha-test discard + depth", @"f_discard", NO, YES } };
    for (int c = 0; c < 5; c++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vq"]; pd.fragmentFunction = [lib newFunctionWithName:v[c].fs]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        if (v[c].blend) { pd.colorAttachments[0].blendingEnabled = YES; pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha; pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne; pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err]; if (!ps) { printf("%s: pipeline failed %s\n", v[c].name, err.localizedDescription.UTF8String); continue; }
        MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new]; ds.depthCompareFunction = v[c].depthTest ? MTLCompareFunctionLessEqual : MTLCompareFunctionAlways; ds.depthWriteEnabled = v[c].depthTest && !v[c].blend; id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:ds];
        double best = 1e9, sum = 0;
        for (int it = 0; it < iters + 3; it++) {
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = color; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:ps]; [e setDepthStencilState:dss];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:layers]; [e endEncoding];
            double t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; [cb commit]; [cb waitUntilCompleted]; double ms = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6 - t0;
            if (it >= 3) { sum += ms; if (ms < best) best = ms; } }
        double avg = sum / iters, gpix = (double)W * H * layers / (avg / 1000.0) / 1e9;
        printf("%-38s avg %7.2f ms  best %7.2f ms  => %6.2f Gpixel/s\n", v[c].name, avg, best, gpix);
    }
    return 0; } }
