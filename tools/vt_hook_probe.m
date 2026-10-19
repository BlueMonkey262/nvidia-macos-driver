// vt_hook_probe: does plugin/nvmtl_vt_spec_hook.h redirect this image's own calls into VideoToolbox? The header is included
// with stubs, installed, and VTCompressionSessionCreate is then called with EnableLowLatencyRateControl in the
// specification, once for H.264 and once for HEVC: the hook must drop the key (its log line) before each call reaches
// VideoToolbox. Built with different linker settings by tools/test_vt_spec_hook.py (lazy pointers that are still unbound
// when the hook installs, bind at load, chained fixups). No GPU is needed: Apple's software encoder answers. The two-slot
// property cache is not exercised here, because this process's VideoToolbox does not answer with the nvenc encoder ids.
// Not compiled on the dev machine (macOS only).
// build: clang -fobjc-arc -mmacosx-version-min=<v> [-Wl,-bind_at_load] -DHOOK_HEADER='"<path>"' -o vt_hook_probe vt_hook_probe.m \
//          -framework Foundation -framework VideoToolbox -framework CoreMedia
// exit: 0 the key was dropped once for H.264 and once for HEVC, 1 it was not, 2 the process crashed or failed early
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
static int g_dropped, g_hevc_dropped;
#define nvlog(...) do { char b_[512]; snprintf(b_, sizeof b_, __VA_ARGS__); \
    if (strstr(b_, "dropped EnableLowLatencyRateControl")) { g_dropped++; if (strstr(b_, "HEVC")) g_hevc_dropped++; } \
    printf("  [nvlog] %s\n", b_); } while (0)
#ifndef HOOK_HEADER
#define HOOK_HEADER "../plugin/nvmtl_vt_spec_hook.h"
#endif
#include HOOK_HEADER
static void out_cb(void *r, void *s, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) {}
static void try_codec(CMVideoCodecType codec, const char *name)
{
    NSDictionary *spec = @{ @"EnableLowLatencyRateControl": @YES };
    VTCompressionSessionRef s = NULL;
    OSStatus r = VTCompressionSessionCreate(NULL, 640, 360, codec, (__bridge CFDictionaryRef)spec, NULL, NULL, out_cb, NULL, &s);
    printf("VTCompressionSessionCreate %s -> %d\n", name, (int)r);
    if (s) VTCompressionSessionInvalidate(s);
}
int main(void)
{
    const int hook_off = getenv("NVMTL_NO_VT_SPEC_HOOK") != NULL;   // read now: the driver plugin loaded later clears NVMTL_* variables
    nvmtl_vt_spec_hook_install();                      // before any call: a lazy pointer is still unbound here
    try_codec(kCMVideoCodecType_H264, "avc1");
    try_codec(kCMVideoCodecType_HEVC, "hvc1");
    printf("key dropped %d time(s), hevc %d\n", g_dropped, g_hevc_dropped);
    const int ok = hook_off ? (g_dropped == 0 && g_hevc_dropped == 0) : (g_dropped == 2 && g_hevc_dropped == 1);
    fflush(stdout);
    _exit(ok ? 0 : 1);   // not exit(): the real driver plugin may be loaded in this process too, and its teardown must not decide the result
}
