// Shared VM-only harness for the surface seed and blocking-wait probes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;
static void check(BOOL ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL %s\n", what); failures++; }
}
static double cpu_seconds(void) {
    struct timespec t; clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void (*stats)(uint64_t *, unsigned);
static uint64_t submits(void) {
    uint64_t s[2] = {0}; stats(s, 2);
    if (!s[0] || s[0] == UINT64_MAX) { fprintf(stderr, "SKIP G-SUB counters unavailable\n"); exit(77); }
    return s[1];
}
static void surface_in(id<MTLTexture> t) {
    ((void (*)(id, SEL))objc_msgSend)(t, NSSelectorFromString(@"nvmtlSurfaceIn"));
}
static IOSurfaceRef make_surface(NSUInteger w, NSUInteger h) {
    return IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge id)kIOSurfaceWidth:@(w), (__bridge id)kIOSurfaceHeight:@(h),
        (__bridge id)kIOSurfaceBytesPerElement:@4, (__bridge id)kIOSurfacePixelFormat:@((uint32_t)'BGRA'),
        (__bridge id)kIOSurfaceIsGlobal:@YES});
}
static void fill_surface(IOSurfaceRef s, unsigned char value) {
    check(IOSurfaceLock(s, 0, NULL) == kIOReturnSuccess, "CPU lock");
    unsigned char *p = IOSurfaceGetBaseAddress(s); size_t row = IOSurfaceGetBytesPerRow(s);
    for (size_t y = 0; y < IOSurfaceGetHeight(s); y++) memset(p + y * row, value, IOSurfaceGetWidth(s) * 4);
    check(IOSurfaceUnlock(s, 0, NULL) == kIOReturnSuccess, "CPU unlock");
}
static id<MTLTexture> texture(id<MTLDevice> d, IOSurfaceRef s, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> t = [d newTextureWithDescriptor:td iosurface:s plane:0];
    if (!t) { fprintf(stderr, "FAIL surface texture allocation\n"); exit(1); }
    return t;
}
static id<MTLCommandBuffer> copy_texture(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> t, id<MTLBuffer> *out) {
    *out = [d newBufferWithLength:t.width * t.height * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLBlitCommandEncoder> b = [c blitCommandEncoder];
    if (!*out || !c || !b) { fprintf(stderr, "FAIL copy allocation\n"); exit(1); }
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:*out destinationOffset:0
        destinationBytesPerRow:t.width * 4 destinationBytesPerImage:t.width * t.height * 4];
    [b endEncoding]; [c commit]; return c;
}
static void verify(id<MTLDevice> d, id<MTLCommandQueue> q, id<MTLTexture> t, unsigned char value) {
    id<MTLBuffer> b; id<MTLCommandBuffer> c = copy_texture(d, q, t, &b); [c waitUntilCompleted];
    check(c.status == MTLCommandBufferStatusCompleted, "GPU readback completion");
    const unsigned char *p = b.contents;
    BOOL ok = p != NULL;
    for (NSUInteger i = 0; p && i < t.width * t.height * 4; i++) if (p[i] != value) { ok = NO; break; }
    check(ok, "GPU bytes equal current IOSurface pixels");
}
static id<MTLDevice> device(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d || ![NSStringFromClass([d class]) hasPrefix:@"NVMTL"]) {
        fprintf(stderr, "SKIP needs NVMTL device\n"); exit(77);
    }
    void *plugin = dlopen(class_getImageName(object_getClass(d)), RTLD_NOW | RTLD_LOCAL);
    stats = plugin ? dlsym(plugin, "nvmtl_vk_gsub_nvk_stats") : NULL;
    if (!stats) { fprintf(stderr, "SKIP needs G-SUB stats\n"); exit(77); }
    return d;
}
static void external_write(const char *exe, IOSurfaceRef s, unsigned value) {
    char sid[32], val[16]; snprintf(sid, sizeof sid, "%u", IOSurfaceGetID(s)); snprintf(val, sizeof val, "%u", value);
    char *args[] = {(char *)exe, "--write", sid, val, NULL}; pid_t pid = 0; extern char **environ;
    int rc = posix_spawn(&pid, exe, NULL, NULL, args, environ), status = 0;
    check(!rc, "spawn cross-process writer");
    if (!rc) check(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && !WEXITSTATUS(status), "cross-process writer exits successfully");
}
static int child_write(int argc, char **argv) {
    if (argc != 4 || strcmp(argv[1], "--write")) return -1;
    IOSurfaceRef s = IOSurfaceLookup((IOSurfaceID)strtoul(argv[2], NULL, 10));
    if (!s) return 1;
    fill_surface(s, (unsigned char)strtoul(argv[3], NULL, 10)); CFRelease(s); return failures ? 1 : 0;
}
static void lifetime_cases(id<MTLDevice> d, id<MTLCommandQueue> q) {
    // IOSurface dimensions are immutable: resize means create a new surface/texture.
    const NSUInteger widths[] = {64, 128, 32, 64};
    for (unsigned j = 0; j < 4; j++) @autoreleasepool {
        IOSurfaceRef s = make_surface(widths[j], 16); check(s != NULL, "recreated surface");
        if (!s) continue;
        fill_surface(s, 37 + j); id<MTLTexture> t = texture(d, s, widths[j], 16);
        surface_in(t); verify(d, q, t, 37 + j);
        id<MTLBuffer> b; id<MTLCommandBuffer> c = copy_texture(d, q, t, &b);
        t = nil; CFRelease(s); // Application releases both while a command buffer may still be pending.
        [c waitUntilCompleted]; check(c.status == MTLCommandBufferStatusCompleted, "destroy while pending");
        const unsigned char *p = b.contents;
        check(p && p[0] == 37 + j && p[widths[j] * 16 * 4 - 1] == 37 + j, "retained pending surface bytes");
    }
}
