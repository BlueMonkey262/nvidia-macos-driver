// Build: clang -arch x86_64 -fobjc-arc tools/gpu_compute_check.m -o gpu_compute_check -framework Foundation -framework Metal
// Run: ./gpu_compute_check; exit 0 pass, 1 fail.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue=[device newCommandQueue];
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nkernel void check(device uint *p [[buffer(0)]],uint i [[thread_position_in_grid]]) { if(i<4096) p[i]=i*3u+7u; }";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLFunction> function=[library newFunctionWithName:@"check"];
    id<MTLComputePipelineState> pipeline=function?[device newComputePipelineStateWithFunction:function error:&error]:nil;
    id<MTLBuffer> buffer=[device newBufferWithLength:4096*sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if(!queue || !pipeline || !buffer) { fprintf(stderr,"compute setup failed: %s\n",error.description.UTF8String?:"no Metal device, queue or buffer");return 1; }
    memset(buffer.contents,0,buffer.length);
    id<MTLCommandBuffer> commands=[queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[commands computeCommandEncoder];
    if(!commands || !encoder) { fprintf(stderr,"compute command allocation failed\n");return 1; }
    [encoder setComputePipelineState:pipeline];[encoder setBuffer:buffer offset:0 atIndex:0];
    NSUInteger threads=MIN((NSUInteger)256,pipeline.maxTotalThreadsPerThreadgroup);
    [encoder dispatchThreadgroups:MTLSizeMake((4096+threads-1)/threads,1,1) threadsPerThreadgroup:MTLSizeMake(threads,1,1)];
    [encoder endEncoding];[commands commit];[commands waitUntilCompleted];
    if(commands.status!=MTLCommandBufferStatusCompleted) { fprintf(stderr,"compute failed: %s\n",commands.error.description.UTF8String?:"command not completed");return 1; }
    const uint32_t *values=buffer.contents;
    for(unsigned i=0;i<4096;i++) if(values[i]!=i*3u+7u) { fprintf(stderr,"item %u: got %u expected %u\n",i,values[i],i*3u+7u);return 1; }
    printf("PASS: 4096 of 4096 compute results verified\n");return 0;
} }
