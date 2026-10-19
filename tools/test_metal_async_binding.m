// test_metal_async_binding: async library/mesh compile off the caller thread,
// sampler MTLBinding.type == MTLBindingTypeSampler, and stageInputAttributes
// returns real MTLAttribute objects (not a C-cast of MTLVertexAttribute).
//
// build: clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_async_binding \
//          tools/test_metal_async_binding.m
// run:   ./test_metal_async_binding
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

static void check_async_source(id<MTLDevice> d) {
    __block _Atomic int called = 0;
    __block int ok = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                    @"kernel void k(device uint *o [[buffer(0)]]) { o[0]=1; }\n";
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [d newLibraryWithSource:src options:nil completionHandler:^(id<MTLLibrary> lib, NSError *err) {
        ok = (lib != nil);
        atomic_store(&called, 1);
        dispatch_semaphore_signal(sem);
        (void)err;
    }];
    CFAbsoluteTime returned = CFAbsoluteTimeGetCurrent() - t0;
    if (atomic_load(&called))
        fail(@"newLibraryWithSource:completionHandler: ran on caller stack before return");
    else
        pass(@"newLibraryWithSource:completionHandler: not called before return");
    // Sync-on-caller then async-handler returns only after compile; async-work returns promptly.
    if (returned > 0.25)
        fail([NSString stringWithFormat:@"newLibraryWithSource:completionHandler: returned after %.3fs (compile likely still on caller)", returned]);
    else
        pass(@"newLibraryWithSource:completionHandler: returned before long compile");
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    if (!atomic_load(&called)) fail(@"newLibraryWithSource:completionHandler: never called");
    else if (!ok) fail(@"newLibraryWithSource:completionHandler: library nil");
}

static void check_async_stitched(id<MTLDevice> d) {
    Class stitchDesc = NSClassFromString(@"MTLStitchedLibraryDescriptor");
    if (!stitchDesc || ![d respondsToSelector:@selector(newLibraryWithStitchedDescriptor:completionHandler:)]) {
        pass(@"newLibraryWithStitchedDescriptor:completionHandler: API absent (skipped)");
        return;
    }
    __block _Atomic int called = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    id desc = [stitchDesc new];
    [d newLibraryWithStitchedDescriptor:desc completionHandler:^(id<MTLLibrary> lib, NSError *err) {
        atomic_store(&called, 1);
        dispatch_semaphore_signal(sem);
        (void)lib; (void)err;
    }];
    if (atomic_load(&called))
        fail(@"newLibraryWithStitchedDescriptor:completionHandler: called before return");
    else
        pass(@"newLibraryWithStitchedDescriptor:completionHandler: not called before return");
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    if (!atomic_load(&called))
        fail(@"newLibraryWithStitchedDescriptor:completionHandler: never called");
}

static void check_sampler_binding_type(id<MTLDevice> d) {
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                    @"kernel void k(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],\n"
                    @"              device float *o [[buffer(0)]]) {\n"
                    @"  o[0] = t.sample(s, float2(0)).r;\n"
                    @"}\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"k"];
    if (!fn) { fail([NSString stringWithFormat:@"sampler setup: %@", err]); return; }
    MTLComputePipelineReflection *refl = nil;
    id<MTLComputePipelineState> ps =
        [d newComputePipelineStateWithFunction:fn options:MTLPipelineOptionArgumentInfo reflection:&refl error:&err];
    if (!ps || !refl) { fail([NSString stringWithFormat:@"sampler pipeline: %@", err]); return; }
    id<MTLBinding> sampler = nil;
    for (id<MTLBinding> b in refl.bindings) {
        if ((NSInteger)b.type == (NSInteger)MTLBindingTypeSampler) {
            sampler = b; break;
        }
    }
    if (!sampler) { fail(@"no sampler binding in compute reflection"); return; }
    if ((NSInteger)sampler.type != (NSInteger)MTLBindingTypeSampler)
        fail([NSString stringWithFormat:@"sampler binding type=%ld want MTLBindingTypeSampler", (long)sampler.type]);
    else
        pass(@"sampler MTLBinding.type == MTLBindingTypeSampler");
}

static void check_stage_input_attributes(id<MTLDevice> d) {
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                    @"struct VIn { float4 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };\n"
                    @"vertex float4 v(VIn in [[stage_in]]) { return in.pos; }\n"
                    @"fragment float4 f() { return float4(1); }\n";
    id<MTLLibrary> lib = [d newLibraryWithSource:src options:nil error:&err];
    id<MTLFunction> vfn = [lib newFunctionWithName:@"v"];
    if (!vfn) { fail([NSString stringWithFormat:@"stageInput setup: %@", err]); return; }
    NSArray *va = vfn.vertexAttributes;
    NSArray *sa = vfn.stageInputAttributes;
    if (sa.count < 1) { fail(@"stageInputAttributes empty"); return; }
    id firstVa = va.firstObject, firstSa = sa.firstObject;
    if ([firstVa class] == [firstSa class])
        fail([NSString stringWithFormat:@"stageInputAttributes class %@ same as vertexAttributes (still a C-cast?)",
              NSStringFromClass([firstSa class])]);
    else
        pass(@"stageInputAttributes uses a distinct class from vertexAttributes");
    if (![firstSa respondsToSelector:@selector(attributeIndex)] || ![firstSa respondsToSelector:@selector(attributeType)])
        fail(@"stageInputAttributes element missing MTLAttribute selectors");
    else if ([firstSa attributeIndex] != 0 && [firstSa attributeIndex] != 1)
        fail([NSString stringWithFormat:@"stageInput attributeIndex=%lu unexpected", (unsigned long)[firstSa attributeIndex]]);
    else
        pass(@"stageInputAttributes elements respond as MTLAttribute");
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d) { fprintf(stderr, "PROBE_ERROR: no Metal device\n"); return 2; }
        printf("device: %s\n", d.name.UTF8String);
        check_async_source(d);
        check_async_stitched(d);
        check_sampler_binding_type(d);
        check_stage_input_attributes(d);
        if (g_fail) { fprintf(stderr, "RESULT: FAILED\n"); return 1; }
        printf("RESULT: OK\n");
        return 0;
    }
}
