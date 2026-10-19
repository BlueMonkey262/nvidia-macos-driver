// Keep more than 32 distinct LOD variants alive in recorded work before submission.
// build: clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_lod_lifetime tools/test_metal_lod_lifetime.m
// run: ./test_metal_lod_lifetime
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>

enum { kVariants = 64 };

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [d newCommandQueue];
        NSError *err = nil;
        id<MTLLibrary> lib = [d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void k(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],\n"
            "device float *o [[buffer(0)]]) { o[0]=t.sample(s,float2(0.5),level(0.0)).r; }\n"
            options:nil error:&err];
        if (!lib) { NSLog(@"PROBE_ERROR: library %@", err); return 2; }
        id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:4 height:4 mipmapped:YES];
        td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [d newTextureWithDescriptor:td];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.mipFilter = MTLSamplerMipFilterNearest;
        id<MTLSamplerState> sampler = [d newSamplerStateWithDescriptor:sd];
        id<MTLBuffer> out = [d newBufferWithLength:kVariants * 256 options:MTLResourceStorageModeShared];
        if (!q || !ps || !tex || !sampler || !out) { NSLog(@"PROBE_ERROR: setup %@", err); return 2; }
        for (NSUInteger mip = 0; mip < 3; mip++) {
            uint8_t bytes[64]; memset(bytes, (int)(32 + 64 * mip), sizeof bytes);
            NSUInteger size = 4 >> mip;
            [tex replaceRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:mip withBytes:bytes bytesPerRow:size * 4];
        }
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        if (!cb || !enc) return 2;
        [enc setComputePipelineState:ps]; [enc setTexture:tex atIndex:0];
        BOOL shim = [NSStringFromClass([(id)sampler class]) hasPrefix:@"NVMTL"];
        NSHashTable *variants = [NSHashTable weakObjectsHashTable];
        @autoreleasepool {
            for (NSUInteger i = 0; i < kVariants; i++) {
                @autoreleasepool {
                    float lo = (i & 1 ? 2.f : 0.f) + (float)i / 1024.f;
                    [enc setSamplerState:sampler lodMinClamp:lo lodMaxClamp:lo + 1.f atIndex:0];
                    [enc setBuffer:out offset:i * 256 atIndex:0];
                    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                    // Observe ownership without keeping variants alive ourselves; a GPU use-after-free need not crash.
                    if (shim) for (id v in [[(id)sampler valueForKey:@"lodClampSamplers"] allValues]) [variants addObject:v];
                }
            }
        }
        [enc endEncoding]; enc = nil;
        NSUInteger live;
        @autoreleasepool { live = variants.allObjects.count; }
        int failed = shim && live < kVariants;
        if (failed) {
            fprintf(stderr, "FAIL: only %lu of %u recorded variants survived eviction\n", (unsigned long)live, kVariants);
            return 1;
        }
        [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { NSLog(@"FAIL: %@", cb.error); return 1; }
        for (NSUInteger i = 0; i < kVariants; i++) {
            float want = (i & 1 ? 160.f : 32.f) / 255.f;
            float got = *(float *)((uint8_t *)out.contents + i * 256);
            if (!isfinite(got) || fabsf(got - want) > 0.002f) { fprintf(stderr, "FAIL: sample %lu got %g want %g\n", (unsigned long)i, got, want); failed = 1; }
        }
        if (failed) return 1;
        printf("PASS: recorded LOD variants survive eviction and produce correct samples\n");
        return 0;
    }
}
