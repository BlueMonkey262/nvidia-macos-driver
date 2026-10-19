// test_metal_api_semantics: public-API checks for Metal semantics fixed in the NVMTL driver
// (async completion handlers, buffer WithBytes storage modes, pipeline/library/function/binding
// property round-trips). Runs against the default Metal device on macOS.
//
// build: clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_api_semantics \
//          tools/test_metal_api_semantics.m
// run:   ./test_metal_api_semantics
// exit:  0 all checks passed, 1 a check failed, 2 setup failed
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <stdatomic.h>

static int g_fail;

static void fail(NSString *s) {
    fprintf(stderr, "FAIL: %s\n", s.UTF8String);
    g_fail = 1;
}
static void pass(NSString *s) { printf("PASS: %s\n", s.UTF8String); }

static void check_async_library(id<MTLDevice> d) {
    __block _Atomic int called = 0;
    __block int before_return = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device uint *o [[buffer(0)]]) { o[0]=1; }\n";
    [d newLibraryWithSource:src options:nil completionHandler:^(id<MTLLibrary> lib, NSError *err) {
        atomic_store(&called, 1);
        dispatch_semaphore_signal(sem);
        (void)lib; (void)err;
    }];
    before_return = atomic_load(&called);
    if (before_return) fail(@"newLibraryWithSource:completionHandler: ran on caller stack before return");
    else pass(@"newLibraryWithSource:completionHandler: not called before return");
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    if (!atomic_load(&called)) fail(@"newLibraryWithSource:completionHandler: never called");
}

static void check_async_specialize(id<MTLDevice> d) {
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nconstant uint C [[function_constant(0)]];\nkernel void k(device uint *o [[buffer(0)]]) { o[0]=C; }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { fail([NSString stringWithFormat:@"specialize setup library: %@", err]); return; }
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
    uint32_t c = 7; [cv setConstantValue:&c type:MTLDataTypeUInt atIndex:0];
    __block _Atomic int called = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [lib newFunctionWithName:@"k" constantValues:cv completionHandler:^(id<MTLFunction> f, NSError *e) {
        atomic_store(&called, 1);
        dispatch_semaphore_signal(sem);
        (void)f; (void)e;
    }];
    if (atomic_load(&called)) fail(@"newFunctionWithName:constantValues:completionHandler: called before return");
    else pass(@"newFunctionWithName:constantValues:completionHandler: not called before return");
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    if (!atomic_load(&called)) fail(@"newFunctionWithName:constantValues:completionHandler: never called");
}

static void check_buffer_bytes(id<MTLDevice> d) {
    const char bytes[4] = {1, 2, 3, 4};
    id<MTLBuffer> priv = [d newBufferWithBytes:bytes length:sizeof bytes options:MTLResourceStorageModePrivate];
    if (priv) fail(@"newBufferWithBytes: Private should return nil");
    else pass(@"newBufferWithBytes: Private -> nil");
    id<MTLBuffer> ok = [d newBufferWithBytes:bytes length:sizeof bytes options:MTLResourceStorageModeShared];
    if (!ok || memcmp(ok.contents, bytes, sizeof bytes)) fail(@"newBufferWithBytes: Shared copy");
    else pass(@"newBufferWithBytes: Shared copies bytes");
}

static void check_pipeline_maxt(id<MTLDevice> d) {
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                    @"[[max_total_threads_per_threadgroup(64)]]\n"
                    @"kernel void k(device uint *o [[buffer(0)]], uint tid [[thread_position_in_threadgroup]]) { if (tid==0) o[0]=64; }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"k"];
    id<MTLComputePipelineState> ps = fn ? [d newComputePipelineStateWithFunction:fn error:&err] : nil;
    if (!ps) { fail([NSString stringWithFormat:@"compute pipeline: %@", err]); return; }
    if (ps.maxTotalThreadsPerThreadgroup != 64)
        fail([NSString stringWithFormat:@"compute maxTotalThreadsPerThreadgroup=%lu want 64",
              (unsigned long)ps.maxTotalThreadsPerThreadgroup]);
    else pass(@"compute maxTotalThreadsPerThreadgroup matches [[max_total_threads_per_threadgroup(64)]]");
}

static void check_function_options(id<MTLDevice> d) {
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device uint *o [[buffer(0)]]) { o[0]=0; }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    if (!lib) { fail([NSString stringWithFormat:@"options library: %@", err]); return; }
    MTLFunctionDescriptor *desc = [MTLFunctionDescriptor functionDescriptor];
    desc.name = @"k";
    MTLFunctionOptions want = (MTLFunctionOptions)1; // MTLFunctionOptionCompileToBinary
    if ([desc respondsToSelector:@selector(setOptions:)]) desc.options = want;
    id<MTLFunction> f = [lib newFunctionWithDescriptor:desc error:&err];
    if (!f) { fail([NSString stringWithFormat:@"newFunctionWithDescriptor: %@", err]); return; }
    if ([f respondsToSelector:@selector(options)] && [desc respondsToSelector:@selector(options)]) {
        if (f.options != want)
            fail([NSString stringWithFormat:@"function.options=%lu want %lu",
                  (unsigned long)f.options, (unsigned long)want]);
        else pass(@"function.options round-trips from MTLFunctionDescriptor");
    } else {
        pass(@"function.options API absent on this SDK (skipped round-trip)");
    }
}

static void check_argument_encoder_length(id<MTLDevice> d) {
    MTLArgumentDescriptor *a = [MTLArgumentDescriptor argumentDescriptor];
    a.dataType = MTLDataTypeFloat; a.index = 0; a.arrayLength = 1;
    id<MTLArgumentEncoder> e = [d newArgumentEncoderWithArguments:@[a]];
    if (!e) { fail(@"newArgumentEncoderWithArguments: nil"); return; }
    // One float is 4 bytes; the old encoder always ended fields at +8.
    if (e.encodedLength != 4)
        fail([NSString stringWithFormat:@"encodedLength=%lu want 4", (unsigned long)e.encodedLength]);
    else pass(@"newArgumentEncoderWithArguments: encodedLength uses field size (4)");
}

static void check_shader_validation(id<MTLDevice> d) {
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device uint *o [[buffer(0)]]) { o[0]=0; }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"k"];
    if (!fn) { fail(@"shaderValidation setup"); return; }
    MTLComputePipelineDescriptor *cd = [MTLComputePipelineDescriptor new];
    cd.computeFunction = fn;
    if (![cd respondsToSelector:@selector(setShaderValidation:)]) {
        pass(@"shaderValidation absent on this SDK (skipped)");
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    cd.shaderValidation = MTLShaderValidationEnabled;
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionNone
                                                                  reflection:nil error:&err];
    if (!ps) { fail([NSString stringWithFormat:@"shaderValidation pipeline: %@", err]); return; }
    if (ps.shaderValidation != MTLShaderValidationEnabled)
        fail([NSString stringWithFormat:@"compute shaderValidation=%ld want Enabled", (long)ps.shaderValidation]);
    else pass(@"compute shaderValidation round-trips from descriptor");
#pragma clang diagnostic pop
}

static void check_render_gpu_resource_id(id<MTLDevice> d) {
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                    @"vertex float4 v() { return float4(0); }\n"
                    @"fragment float4 f() { return float4(1); }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"v"];
    rd.fragmentFunction = [lib newFunctionWithName:@"f"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    rd.supportIndirectCommandBuffers = NO;
    id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:rd error:&err];
    if (!ps) { fail([NSString stringWithFormat:@"render pipeline: %@", err]); return; }
    if (ps.gpuResourceID._impl == 0) fail(@"render gpuResourceID is 0 without ICB");
    else pass(@"render gpuResourceID non-zero without supportIndirectCommandBuffers");
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) { fprintf(stderr, "PROBE_ERROR: no Metal device\n"); return 2; }
        printf("device: %s\n", d.name.UTF8String);
        check_async_library(d);
        check_async_specialize(d);
        check_buffer_bytes(d);
        check_pipeline_maxt(d);
        check_function_options(d);
        check_argument_encoder_length(d);
        check_shader_validation(d);
        check_render_gpu_resource_id(d);
        if (g_fail) { fprintf(stderr, "RESULT: FAILED\n"); return 1; }
        printf("RESULT: OK\n");
        return 0;
    }
}
