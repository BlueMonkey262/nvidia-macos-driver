// An argument encoder must not let an exception escape when the app hands it an object that is not one of ours.
// No Man's Sky ended with -[NVMTLArgumentEncoder setTexture:atIndex:] -> unrecognized selector (crash dumps of
// 2026-10-18 and 2026-10-20). This probe passes a plain NSObject as a texture, a sampler, a render pipeline, a compute
// pipeline and an indirect command buffer, and requires that none of them raises; it also requires that a real
// texture and a real sampler still write a non-zero handle into the argument buffer.
// The installed driver raises (the probe fails); the fixed plugin writes a null handle and logs the class.
//
// Exits 0 pass, 1 fail, 77 skip. On the VM:
//   ~/purple/run_theme.sh THEME test_metal_argenc_foreign.m
//
//   xcrun clang -fobjc-arc -O1 -include "$HOME/purple/nm_shim.h" \
//     -framework Foundation -framework Metal -o /tmp/test_metal_argenc_foreign tools/test_metal_argenc_foreign.m
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

static int g_fail;
static void bad(const char *msg) { fprintf(stderr, "PROBE_ERROR: %s\n", msg); g_fail = 1; }

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "SKIP no Metal device\n"); return 77; }
        NSString *src =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "struct S { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
             "kernel void k(constant S &a [[buffer(0)]], device float *o [[buffer(1)]]) { o[0] = a.t.read(uint2(0)).x; }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"k"] : nil;
        if (!fn) { fprintf(stderr, "SKIP cannot build the test function: %s\n", err.localizedDescription.UTF8String); return 77; }
        id<MTLArgumentEncoder> enc = [fn newArgumentEncoderWithBufferIndex:0];
        if (!enc) { fprintf(stderr, "SKIP no argument encoder\n"); return 77; }
        id<MTLBuffer> buf = [dev newBufferWithLength:enc.encodedLength options:MTLResourceStorageModeShared];
        [enc setArgumentBuffer:buf offset:0];

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                       width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.supportArgumentBuffers = YES;
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        if (!tex || !smp) { fprintf(stderr, "SKIP cannot create a texture/sampler\n"); return 77; }

        uint64_t *words = (uint64_t *)buf.contents;
        memset(words, 0, buf.length);
        [enc setTexture:tex atIndex:0];
        [enc setSamplerState:smp atIndex:1];
        printf("observation: real texture handle 0x%llx, real sampler handle 0x%llx\n",
               (unsigned long long)words[0], (unsigned long long)words[1]);
        if (!words[0]) bad("a real texture wrote a null handle");

        id foreign = [NSObject new];
        const char *what[] = { "texture", "sampler", "render pipeline", "compute pipeline", "indirect command buffer" };
        for (int i = 0; i < 5; i++) {
            @try {
                switch (i) {
                    case 0: [enc setTexture:(id<MTLTexture>)foreign atIndex:0]; break;
                    case 1: [enc setSamplerState:(id<MTLSamplerState>)foreign atIndex:1]; break;
                    case 2: [enc setRenderPipelineState:(id<MTLRenderPipelineState>)foreign atIndex:0]; break;
                    case 3: [enc setComputePipelineState:(id<MTLComputePipelineState>)foreign atIndex:0]; break;
                    case 4: [enc setIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)foreign atIndex:0]; break;
                }
                printf("observation: foreign %s accepted without an exception\n", what[i]);
            } @catch (NSException *e) {
                fprintf(stderr, "PROBE_ERROR: foreign %s raised %s: %s\n", what[i], e.name.UTF8String, e.reason.UTF8String);
                g_fail = 1;
            }
        }
        // The null handle must replace, not keep, an earlier real one.
        if (!g_fail && words[0] != 0) bad("a foreign texture left the earlier handle in place instead of a null handle");
        printf(g_fail ? "FAIL argument encoder foreign objects\n" : "ok argument encoder foreign objects\n");
        return g_fail;
    }
}
