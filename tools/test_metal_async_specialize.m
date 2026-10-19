// Instrument the shim's synchronous specialization entry to detect work on the caller thread.
// build: clang -fobjc-arc -framework Metal -framework Foundation -o test_metal_async_specialize tools/test_metal_async_specialize.m
// run: ./test_metal_async_specialize
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>

static pthread_t caller;
static _Atomic int entered, onCaller;
static IMP original;
typedef id<MTLFunction> (*SpecializeIMP)(id, SEL, NSString *, MTLFunctionConstantValues *, NSError **) __attribute__((ns_returns_retained));
static id<MTLFunction> specialize(id self, SEL sel, NSString *name, MTLFunctionConstantValues *cv, NSError **err) __attribute__((ns_returns_retained));
static id<MTLFunction> specialize(id self, SEL sel, NSString *name, MTLFunctionConstantValues *cv, NSError **err) {
    atomic_fetch_add(&entered, 1);
    if (pthread_equal(pthread_self(), caller)) atomic_store(&onCaller, 1);
    return ((SpecializeIMP)original)(self, sel, name, cv, err);
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        id<MTLLibrary> lib = [d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "constant uint C [[function_constant(0)]];\n"
            "kernel void k(device uint *o [[buffer(0)]]) { o[0]=C; }\n" options:nil error:&err];
        if (!lib) { NSLog(@"PROBE_ERROR: %@", err); return 2; }
        Method method = class_getInstanceMethod(object_getClass(lib), @selector(newFunctionWithName:constantValues:error:));
        if (!method) return 2;
        caller = pthread_self();
        original = method_setImplementation(method, (IMP)specialize);
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
        uint32_t c = 7; [cv setConstantValue:&c type:MTLDataTypeUInt atIndex:0];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block id<MTLFunction> fn;
        __block NSError *error;
        __block int callbacks = 0;
        [lib newFunctionWithName:@"k" constantValues:cv completionHandler:^(id<MTLFunction> f, NSError *e) {
            if (pthread_equal(pthread_self(), caller)) atomic_store(&onCaller, 1);
            fn = f; error = e; callbacks++;
            dispatch_semaphore_signal(done);
        }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC))) {
            fprintf(stderr, "FAIL: callback timeout\n"); return 1;
        }
        method_setImplementation(method, original);
        if (!fn || error || callbacks != 1 || atomic_load(&entered) != 1 || atomic_load(&onCaller)) {
            NSLog(@"FAIL: specialization entries=%d caller=%d callbacks=%d function=%@ error=%@",
                  atomic_load(&entered), atomic_load(&onCaller), callbacks, fn, error);
            return 1;
        }
        printf("PASS: specialization and callback completed off the caller thread\n");
        return 0;
    }
}
