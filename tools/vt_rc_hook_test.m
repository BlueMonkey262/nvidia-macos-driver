// Exercise the codec selection and output-feedback wiring with fake VT functions.
// No Metal device or encoder is created. Build on macOS with Foundation,
// VideoToolbox and CoreMedia; this tests the real hook header, not a copy of it.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#define nvlog(...) ((void)0)
#include "../plugin/nvmtl_vt_spec_hook.h"

static nvmtl_vt_out_cb callback;
static void *callback_ref;
static int hardware = 1, forwarded, quality_sets, non_sync;
static double quality;
static CFTypeRef fake_session;
static int failures;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); failures++; } } while (0)

static int32_t create(CFAllocatorRef a, int32_t w, int32_t h, uint32_t codec,
                      CFDictionaryRef spec, CFDictionaryRef attrs, CFAllocatorRef ca,
                      void *cb, void *ref, void *out)
{
    CHECK(!CFDictionaryContainsKey(spec, CFSTR("EnableLowLatencyRateControl")));
    callback = (nvmtl_vt_out_cb)cb;
    callback_ref = ref;
    *(CFTypeRef *)out = fake_session;
    return 0;
}
static int32_t copyprop(CFTypeRef s, CFStringRef key, CFAllocatorRef a, void *out)
{
    *(CFTypeRef *)out = CFRetain(hardware ? kCFBooleanTrue : kCFBooleanFalse);
    return 0;
}
static int32_t setprop(CFTypeRef s, CFStringRef key, CFTypeRef val)
{
    if (CFEqual(key, CFSTR("Quality"))) {
        quality_sets++;
        CHECK(CFNumberGetValue((CFNumberRef)val, kCFNumberDoubleType, &quality));
    }
    return 0;
}
static size_t sample_size(CFTypeRef sample) { return 100000; }
static CFArrayRef attachments(CFTypeRef sample, bool create)
{
    static CFArrayRef sync, delta;
    if (!sync) {
        sync = CFBridgingRetain(@[@{}]);
        delta = CFBridgingRetain(@[@{@"NotSync": @YES}]);
    }
    return non_sync ? delta : sync;
}
static void client(void *ref, void *src, int32_t status, uint32_t flags, CFTypeRef sample)
{
    CHECK(ref == (void *)0x1234);
    forwarded++;
}
static void test_codec(uint32_t codec, int hw, int enabled)
{
    hardware = hw;
    g_rc_enabled = enabled;
    quality_sets = forwarded = 0;
    NSDictionary *spec = @{@"EnableLowLatencyRateControl": @YES};
    CFTypeRef session = NULL;
    CHECK(nvmtl_vt_create_hook(NULL, 1280, 720, codec, (__bridge CFDictionaryRef)spec,
                              NULL, NULL, (void *)client, (void *)0x1234, &session) == 0);
    CHECK(session == fake_session);
    CHECK((callback == nvmtl_vt_rc_output) == (enabled != 0));
    double target = 2000000, fps = 60;
    CFNumberRef b = CFNumberCreate(NULL, kCFNumberDoubleType, &target);
    CFNumberRef f = CFNumberCreate(NULL, kCFNumberDoubleType, &fps);
    nvmtl_vt_setprop_hook(session, CFSTR("AverageBitRate"), b);
    nvmtl_vt_setprop_hook(session, CFSTR("ExpectedFrameRate"), f);
    CFRelease(b); CFRelease(f);
    non_sync = 0;
    callback(callback_ref, NULL, 0, 0, CFSTR("key frame"));
    CHECK(quality_sets == 0); // IDR is accounted, but must not change QP
    non_sync = 1;
    callback(callback_ref, NULL, 0, 0, CFSTR("P frame"));
    CHECK(forwarded == 2);
    if (hw && enabled) {
        CHECK(quality_sets == 1);
        CHECK(fabs(quality - nvmtl_vt_rc_quality_for_qp(24)) < 1e-12);
    } else CHECK(quality_sets == 0);
}
int main(void) { @autoreleasepool {
    fake_session = CFRetain(CFSTR("fake VT session"));
    g_vt_create_orig = create;
    g_vt_copyprop = copyprop;
    g_vt_setprop_orig = setprop;
    g_cm_size = sample_size;
    g_cm_att = attachments;
    for (int i = 0; i < 2; i++) {
        uint32_t codec = i ? 'hvc1' : 'avc1';
        test_codec(codec, 1, 1);
        test_codec(codec, 0, 1);
        test_codec(codec, 1, 0);
    }
    printf("%d failed: H.264/HEVC callback feedback, IDR, software and opt-out controls\n", failures);
    CFRelease(fake_session);
    return failures ? 1 : 0;
} }
