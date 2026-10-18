// skymip: can this device build compute pipelines for the compositor's mip-generation kernels?
// Loads the system SkyLight metallib and asks for the five mipGenPolyphase* functions.
// usage: skymip
// build: clang -fobjc-arc -O2 -Wall -o skymip skymip.m -framework Foundation -framework Metal
// exit: 0 PASS (all five pipelines built); 1 at least one failed; 2 the metallib did not load
// output: per kernel, function type and either max threads / threadgroup memory, or the
//   pipeline error truncated to 260 characters, then PASS or FAIL.
// permission: none
// cannot show: that the kernel's output texels are correct, or that WindowServer
//   calls these. A pipeline that builds can still sample badly; minify checks sampling.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSURL *u = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib"];
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithURL:u error:&e]; if (!lib) { printf("load failed\n"); return 2; }
    NSArray *k = @[ @"mipGenPolyphaseFast_Weven_Heven", @"mipGenPolyphaseFast_Weven_Hodd", @"mipGenPolyphaseFast_Wodd_Heven", @"mipGenPolyphaseFast_Wodd_Hodd", @"mipGenPolyphaseRef" ]; int bad = 0;
    for (NSString *n in k) {
        NSError *fe = nil; id<MTLFunction> f = [lib newFunctionWithName:n]; if (!f) { printf("%-36s newFunctionWithName FAILED\n", n.UTF8String); bad++; continue; }
        printf("%-36s type %lu ", n.UTF8String, (unsigned long)f.functionType);
        NSError *pe = nil; id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:f error:&pe];
        if (ps) printf("pipeline OK (maxThreads %lu, tgMem %lu)\n", (unsigned long)ps.maxTotalThreadsPerThreadgroup, (unsigned long)ps.staticThreadgroupMemoryLength);
        else { printf("pipeline FAILED: %s\n", [pe.localizedDescription substringToIndex:MIN(260, pe.localizedDescription.length)].UTF8String); bad++; }
    }
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad ? 1 : 0; } }
