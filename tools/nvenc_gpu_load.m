// Bounded companion workload for encoder stress tests. Holds touched private Metal buffers
// and optionally runs a compute kernel. Does not install/configure the driver or allocate to OOM.
// Usage: nvenc_gpu_load SECONDS MIB COMPUTE(0|1)
// Build: clang -fobjc-arc -O1 tools/nvenc_gpu_load.m -o nvenc_gpu_load -framework Foundation -framework Metal
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <signal.h>
#include <unistd.h>
#include <math.h>
static volatile sig_atomic_t stopped;
static void stop(int s){stopped=1;}
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=4)return 64;int secs=atoi(argv[1]),mib=atoi(argv[2]),compute=atoi(argv[3]);
    if(secs<1 || secs>1800 || mib<32 || mib>3072 || (compute!=0 && compute!=1))return 64;
    signal(SIGTERM,stop);signal(SIGINT,stop);
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> q=[dev newCommandQueue];
    if(!dev || !q)return 2;
    NSMutableArray *buffers=[NSMutableArray array];
    for(int remaining=mib;remaining>0;remaining-=MIN(64,remaining)){
        NSUInteger bytes=(NSUInteger)MIN(64,remaining)*1024*1024;
        id<MTLBuffer> b=[dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];if(!b)return 3;
        [buffers addObject:b];id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
        [e fillBuffer:b range:NSMakeRange(0,bytes) value:0xa5];[e endEncoding];[cb commit];[cb waitUntilCompleted];
        if(cb.status==MTLCommandBufferStatusError)return 4;
    }
    id<MTLComputePipelineState> pipeline=nil;
    if(compute){
        NSError *err=nil;
        NSString *src=@"#include <metal_stdlib>\nusing namespace metal;\nkernel void load(device float4 *p [[buffer(0)]],uint i [[thread_position_in_grid]]) { float4 v=float4(float(i&1023u)*0.0001f); for(uint k=0;k<1024;k++) v=fma(v,float4(0.9999f),float4(0.00001f)); p[i]=v; }";
        id<MTLLibrary> lib=[dev newLibraryWithSource:src options:nil error:&err];pipeline=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"load"] error:&err];
        if(!pipeline){fprintf(stderr,"compute build failed: %s\n",err.description.UTF8String);return 5;}
    }
    printf("READY device=%s private_mib=%d compute=%d\n",dev.name.UTF8String,mib,compute);fflush(stdout);
    double start=CFAbsoluteTimeGetCurrent(),busy=0;unsigned iterations=0;
    while(!stopped && CFAbsoluteTimeGetCurrent()-start<secs){@autoreleasepool{
        if(compute){double t=CFAbsoluteTimeGetCurrent();id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
            [e setComputePipelineState:pipeline];[e setBuffer:buffers[0] offset:0 atIndex:0];
            NSUInteger threads=MIN((NSUInteger)256,pipeline.maxTotalThreadsPerThreadgroup),count=[buffers[0] length]/16;
            [e dispatchThreadgroups:MTLSizeMake((count+threads-1)/threads,1,1) threadsPerThreadgroup:MTLSizeMake(threads,1,1)];
            [e endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status==MTLCommandBufferStatusError)return 6;
            busy+=CFAbsoluteTimeGetCurrent()-t;iterations++;usleep(200);
        }else usleep(100000);
    }}
    // Verify held allocations are still usable, including the final page of each buffer.
    id<MTLBuffer> read=[dev newBufferWithLength:buffers.count*4 options:MTLResourceStorageModeShared];if(!read)return 7;
    id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    for(NSUInteger i=0;i<buffers.count;i++) [blit copyFromBuffer:buffers[i] sourceOffset:[buffers[i] length]-4 toBuffer:read destinationOffset:i*4 size:4];
    [blit endEncoding];[cb commit];[cb waitUntilCompleted];if(cb.status==MTLCommandBufferStatusError)return 8;
    uint32_t *words=read.contents;for(NSUInteger i=compute?1:0;i<buffers.count;i++)if(words[i]!=0xa5a5a5a5u)return 9;
    printf("DONE iterations=%u wall_s=%.2f command_wait_s=%.2f memory_sentinels=ok\n",iterations,CFAbsoluteTimeGetCurrent()-start,busy);fflush(stdout);return 0;
}}
