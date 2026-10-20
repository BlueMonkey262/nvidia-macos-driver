// Exercise both async function APIs, snapshots, errors, re-entry, and concurrent sync/async specialization.
// build: clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_async_specialize tools/test_metal_async_specialize.m
// run: NVMTL_FCCACHE_OFF=1 ./test_metal_async_specialize
// exit: 0 pass / 1 fail / 77 skip (no NVMTL device). No timing thresholds or GPU fault injection.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>

static pthread_t caller;
static _Atomic int entered, descriptorEntered, onCaller, failed;
static IMP original, originalDescriptor;
typedef id<MTLFunction> (*SpecializeIMP)(id, SEL, NSString *, MTLFunctionConstantValues *, NSError **) __attribute__((ns_returns_retained));
typedef id<MTLFunction> (*DescriptorIMP)(id, SEL, MTLFunctionDescriptor *, NSError **) __attribute__((ns_returns_retained));
static id<MTLFunction> specialize(id self, SEL sel, NSString *name, MTLFunctionConstantValues *cv, NSError **err) __attribute__((ns_returns_retained));
static id<MTLFunction> specialize(id self, SEL sel, NSString *name, MTLFunctionConstantValues *cv, NSError **err) {
    atomic_fetch_add(&entered, 1);
    if (pthread_equal(pthread_self(), caller)) atomic_store(&onCaller, 1);
    return ((SpecializeIMP)original)(self, sel, name, cv, err);
}
static id<MTLFunction> descriptor(id self, SEL sel, MTLFunctionDescriptor *desc, NSError **err) __attribute__((ns_returns_retained));
static id<MTLFunction> descriptor(id self, SEL sel, MTLFunctionDescriptor *desc, NSError **err) {
    atomic_fetch_add(&descriptorEntered, 1);
    if (pthread_equal(pthread_self(), caller)) atomic_store(&onCaller, 1);
    return ((DescriptorIMP)originalDescriptor)(self, sel, desc, err);
}
static MTLFunctionConstantValues *values(uint32_t c) {
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
    [cv setConstantValue:&c type:MTLDataTypeUInt atIndex:0];
    return cv;
}
static int run(id<MTLDevice> d, id<MTLFunction> f, uint32_t expected) {
    NSError *err = nil;
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:f error:&err];
    id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLBuffer> out = [d newBufferWithLength:4 options:MTLResourceStorageModeShared];
    if (!ps || !q || !out) { NSLog(@"FAIL: execution setup %@", err); return 1; }
    *(uint32_t *)out.contents = ~expected;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (!cb || !enc) return 1;
    [enc setComputePipelineState:ps]; [enc setBuffer:out offset:0 atIndex:0];
    [enc dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted || *(uint32_t *)out.contents != expected) {
        NSLog(@"FAIL: expected %u got %u, %@", expected, *(uint32_t *)out.contents, cb.error); return 1;
    }
    return 0;
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (!d || ![NSStringFromClass([(id)d class]) hasPrefix:@"NVMTL"]) {
            fprintf(stderr, "SKIP: needs the NVMTL plugin\n"); return 77;
        }
        NSError *err = nil;
        id<MTLLibrary> lib = [d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "constant uint C [[function_constant(0)]];\n"
            "kernel void k(device uint *o [[buffer(0)]]) { o[0]=is_function_constant_defined(C) ? C : 3u; }\n" options:nil error:&err];
        if (!lib) { NSLog(@"FAIL: library %@", err); return 1; }
        Method m = class_getInstanceMethod([(id)lib class], @selector(newFunctionWithName:constantValues:error:));
        Method dm = class_getInstanceMethod([(id)lib class], @selector(newFunctionWithDescriptor:error:));
        if (!m || !dm) return 1;
        caller = pthread_self();
        original = method_setImplementation(m, (IMP)specialize);
        originalDescriptor = method_setImplementation(dm, (IMP)descriptor);
        dispatch_group_t done = dispatch_group_create();
        NSMutableDictionary *functions = [NSMutableDictionary new];
        // Simultaneous distinct constants exercise translator misses; 0 and UINT32_MAX check payload edges.
        for (unsigned i = 0; i < 16; i++) {
            uint32_t c = i == 15 ? UINT32_MAX : i;
            MTLFunctionConstantValues *cv = values(c);
            MTLFunctionDescriptor *desc = [MTLFunctionDescriptor functionDescriptor];
            desc.name = @"k"; desc.constantValues = cv;
            __block unsigned calls = 0;
            dispatch_group_enter(done);
            void (^reply)(id<MTLFunction>, NSError *) = ^(id<MTLFunction> f, NSError *e) {
                if (pthread_equal(pthread_self(), caller)) atomic_store(&onCaller, 1);
                @synchronized (functions) {
                    if (++calls != 1 || !f || e) { NSLog(@"FAIL: callback %u %@", i, e); atomic_store(&failed, 1); }
                    if (f) functions[@(i)] = f;
                }
                // A callback must be able to re-enter the synchronous API without a lock cycle.
                NSError *nestedError = nil;
                if (![lib newFunctionWithName:@"k" constantValues:values(42) error:&nestedError] || nestedError)
                    atomic_store(&failed, 1);
                dispatch_group_leave(done);
            };
            if (i & 1) [lib newFunctionWithDescriptor:desc completionHandler:reply];
            else [lib newFunctionWithName:@"k" constantValues:cv completionHandler:reply];
            // Neither request may depend on later edits to its inputs.
            uint32_t changed = 12345; [cv setConstantValue:&changed type:MTLDataTypeUInt atIndex:0];
            desc.name = @"missing_after_request"; desc.constantValues = values(changed);
        }
        // Concurrent synchronous translation must also share the translator-entry lock.
        dispatch_group_async(done, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
            NSError *e = nil;
            id<MTLFunction> f = [lib newFunctionWithName:@"k" constantValues:values(100) error:&e];
            @synchronized (functions) { if (f && !e) functions[@16] = f; else atomic_store(&failed, 1); }
        }});
        for (unsigned i = 17; i < 19; i++) {
            dispatch_group_enter(done);
            void (^reply)(id<MTLFunction>, NSError *) = ^(id<MTLFunction> f, NSError *e) {
                @synchronized (functions) { if (f && !e) functions[@(i)] = f; else atomic_store(&failed, 1); }
                dispatch_group_leave(done);
            };
            if (i == 17) [lib newFunctionWithName:@"k" constantValues:nil completionHandler:reply];
            else {
                MTLFunctionDescriptor *desc = [MTLFunctionDescriptor functionDescriptor]; desc.name = @"k";
                [lib newFunctionWithDescriptor:desc completionHandler:reply];
            }
        }
        for (unsigned i = 0; i < 4; i++) {
            dispatch_group_enter(done);
            void (^reply)(id<MTLFunction>, NSError *) = ^(id<MTLFunction> f, NSError *e) {
                if (f || !e || pthread_equal(pthread_self(), caller)) atomic_store(&failed, 1);
                dispatch_group_leave(done);
            };
            if (i == 0) [lib newFunctionWithName:@"no_such_function" constantValues:nil completionHandler:reply];
            else {
                MTLFunctionDescriptor *desc = i == 1 ? nil : [MTLFunctionDescriptor functionDescriptor];
                if (i == 2) desc.name = @"no_such_function";
                [lib newFunctionWithDescriptor:desc completionHandler:reply];
            }
        }
        // Plugin-tolerated nil handlers must do no work.
        int before = atomic_load(&onCaller);
        [lib newFunctionWithName:@"k" constantValues:nil completionHandler:nil];
        [lib newFunctionWithDescriptor:nil completionHandler:nil];
        if (atomic_load(&onCaller) != before) atomic_store(&failed, 1);
        if (dispatch_group_wait(done, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC))) {
            fprintf(stderr, "FAIL: callback/re-entry timeout\n"); return 1;
        }
        method_setImplementation(m, original); method_setImplementation(dm, originalDescriptor);
        if (atomic_load(&failed) || atomic_load(&onCaller) || !atomic_load(&entered) ||
            !atomic_load(&descriptorEntered) || functions.count != 19) {
            fprintf(stderr, "FAIL: callback, off-caller, or result-count assertion\n"); return 1;
        }
        for (unsigned i = 0; i < 19; i++) {
            uint32_t c = i >= 17 ? 3 : i == 16 ? 100 : i == 15 ? UINT32_MAX : i;
            if (run(d, functions[@(i)], c) || run(d, functions[@(i)], c)) return 1;
        }
        printf("PASS: both async APIs, snapshots, concurrent sync entry, errors, re-entry and GPU results\n");
        return 0;
    }
}
