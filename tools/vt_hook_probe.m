// vt_hook_probe: does plugin/nvmtl_vt_spec_hook.h redirect this image's own calls into VideoToolbox? The header is included
// with stubs, installed, and VTCompressionSessionCreate is then called with EnableLowLatencyRateControl in the
// specification: the hook must drop the key (its log line) before the call reaches VideoToolbox. Built with different
// linker settings by tools/test_vt_spec_hook.py (lazy pointers that are still unbound when the hook installs, bind at load,
// chained fixups). No GPU is needed: Apple's software encoder answers.
// build: clang -fobjc-arc -mmacosx-version-min=<v> [-Wl,-bind_at_load] -DHOOK_HEADER='"<path>"' -o vt_hook_probe vt_hook_probe.m \
//          -framework Foundation -framework VideoToolbox -framework CoreMedia
// exit: 0 the key was dropped exactly once, 1 it was not (the hook did not see the call), 2 the process crashed or failed early
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
static int g_dropped;
#define nvlog(...) do { char b_[512]; snprintf(b_, sizeof b_, __VA_ARGS__); if (strstr(b_, "dropped EnableLowLatencyRateControl")) g_dropped++; printf("  [nvlog] %s\n", b_); } while (0)
#ifndef HOOK_HEADER
#define HOOK_HEADER "../plugin/nvmtl_vt_spec_hook.h"
#endif
#include HOOK_HEADER
static void out_cb(void *r, void *s, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) {}
int main(void)
{
    const int hook_off = getenv("NVMTL_NO_VT_SPEC_HOOK") != NULL;   // read now: the driver plugin loaded later clears NVMTL_* variables
    nvmtl_vt_spec_hook_install();                      // before any call: a lazy pointer is still unbound here
    NSDictionary *spec = @{ @"EnableLowLatencyRateControl": @YES };
    VTCompressionSessionRef s = NULL;
    OSStatus r = VTCompressionSessionCreate(NULL, 640, 360, kCMVideoCodecType_H264, (__bridge CFDictionaryRef)spec, NULL, NULL, out_cb, NULL, &s);
    printf("VTCompressionSessionCreate -> %d, key dropped %d time(s)\n", (int)r, g_dropped);
    if (s) VTCompressionSessionInvalidate(s);
    const int ok = hook_off ? (g_dropped == 0) : (g_dropped == 1);
    fflush(stdout);
    _exit(ok ? 0 : 1);   // not exit(): the real driver plugin may be loaded in this process too, and its teardown must not decide the result
}
