// fcon: do MTLFunctionConstantValues change what a fragment shader writes?
// A tiny shader gates RGB on three function constants, the way a compositor
// picks UberResample branches. Five specialisations are rendered to 8x8 and read back.
// usage: fcon
// build: clang -fobjc-arc -O2 -Wall -o fcon fcon.m -framework Foundation -framework Metal
// exit: 0 PASS (every pixel within 1 of the expected 8-bit channel); 1 FAIL; 2 the library did not compile
// output: one line per specialisation, rgb found and rgb expected. "none set" must
//   be black: an unspecialised module that took the true branches fails that row.
// permission: none
// cannot show: that WindowServer's constantValues: reach its own shaders. This
//   process specialises its own source. skylib lists the compositor's names.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static NSString *msl = @"#include <metal_stdlib>\nusing namespace metal;\n"
"constant bool enable_a [[function_constant(0)]];\nconstant bool enable_b [[function_constant(1)]];\nconstant int mode [[function_constant(2)]];\nconstant bool has_a = is_function_constant_defined(enable_a);\n"
"struct VO { float4 pos [[position]]; };\n"
"vertex VO vq(uint vid [[vertex_id]]) { float2 q[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; VO o; o.pos = float4(q[vid], 0, 1); return o; }\n"
"fragment float4 fs(VO i [[stage_in]]) { float r = 0.0, g = 0.0, b = 0.0;\n"
"  if (has_a && enable_a) r = 1.0;\n"
"  if (is_function_constant_defined(enable_b) && enable_b) g = 1.0;\n"
"  if (is_function_constant_defined(mode)) b = float(mode) / 4.0;\n"
"  return float4(r, g, b, 1.0); }\n";
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); printf("device %s\n", dev.name.UTF8String);
    NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err]; if (!lib) { printf("compile: %s\n", err.localizedDescription.UTF8String); return 2; }
    id<MTLCommandQueue> q = [dev newCommandQueue]; int bad = 0;
    struct { const char *name; int a, b, mode; int er, eg, eb; } cases[] = {   // a/b: -1 = not set, else bool; mode -1 = not set
        { "none set",                -1, -1, -1,   0,   0,   0 },
        { "a=true",                   1, -1, -1, 255,   0,   0 },
        { "a=false, b=true",          0,  1, -1,   0, 255,   0 },
        { "a=true, b=true, mode=4",   1,  1,  4, 255, 255, 255 },
        { "mode=2 only",             -1, -1,  2,   0,   0, 128 } };
    for (int c = 0; c < 5; c++) {
        MTLFunctionConstantValues *fv = [MTLFunctionConstantValues new];
        if (cases[c].a >= 0) { bool v = cases[c].a; [fv setConstantValue:&v type:MTLDataTypeBool atIndex:0]; }
        if (cases[c].b >= 0) { bool v = cases[c].b; [fv setConstantValue:&v type:MTLDataTypeBool atIndex:1]; }
        if (cases[c].mode >= 0) { int v = cases[c].mode; [fv setConstantValue:&v type:MTLDataTypeInt atIndex:2]; }
        id<MTLFunction> f = [lib newFunctionWithName:@"fs" constantValues:fv error:&err]; if (!f) { printf("%s: function failed: %s\n", cases[c].name, err.localizedDescription.UTF8String); bad++; continue; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vq"]; pd.fragmentFunction = f; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err]; if (!ps) { printf("%s: pipeline failed: %s\n", cases[c].name, err.localizedDescription.UTF8String); bad++; continue; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:ps]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl synchronizeResource:t]; [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
        uint8_t px[4]; [t getBytes:px bytesPerRow:32 fromRegion:MTLRegionMake2D(4, 4, 1, 1) mipmapLevel:0];
        int R = px[2], G = px[1], B = px[0]; BOOL ok = abs(R - cases[c].er) <= 1 && abs(G - cases[c].eg) <= 1 && abs(B - cases[c].eb) <= 1;
        printf("%-26s -> rgb %3d %3d %3d  expected %3d %3d %3d  %s\n", cases[c].name, R, G, B, cases[c].er, cases[c].eg, cases[c].eb, ok ? "ok" : "WRONG: function constants not applied"); if (!ok) bad++;
    }
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad ? 1 : 0;
} }
