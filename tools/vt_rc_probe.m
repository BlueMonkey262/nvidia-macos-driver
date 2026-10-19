// vt_rc_probe: does bitrate control (plugin/nvmtl_vt_spec_hook.h + nvmtl_vt_ratecontrol.h, opt-in NVMTL_VT_RC=1) hold a target
// on the real hardware encoder? A synthetic moving picture (720p60, 360 frames) is encoded with AverageBitRate set; the
// bitrate achieved after the first second is printed per second and overall. Needs the Turing encoder on macOS (a VM with the
// driver), no other process holding the card's BAR1 window (a session needs ~15-33 MB of it).
// usage: [NVMTL_VT_RC=1] [PROBE_CODEC=hevc] vt_rc_probe [target_bits_per_second [frames [sessions]]]
//   target 0 = set no AverageBitRate (the library's constant QP); H.264 is the default codec.
//   sessions > 1 runs that many sessions one after another (create, encode, release) in this process: every one must stay within
//   25% of the target, which catches a control table that fills up. exit: 0 ok, 1 a session was out of window, 2 create failed
// build: clang -fobjc-arc -DHOOK_HEADER='"<path>/plugin/nvmtl_vt_spec_hook.h"' -o vt_rc_probe tools/vt_rc_probe.m \
//          -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>
#include <math.h>
#include <pthread.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#define nvlog(...) do { char b_[512]; snprintf(b_, sizeof b_, __VA_ARGS__); printf("  [nvlog] %s\n", b_); } while (0)
#ifndef HOOK_HEADER
#define HOOK_HEADER "../plugin/nvmtl_vt_spec_hook.h"
#endif
#include HOOK_HEADER
static NSMutableArray *g_sizes; static NSMutableArray *g_idr;
static CMVideoCodecType g_codec = kCMVideoCodecType_H264;
static void out_cb(void *r, void *src, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb)
{
    if (st || !sb) return;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false); BOOL key = YES;
    if (att && CFArrayGetCount(att)) { NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(att, 0); if ([d[@"NotSync"] boolValue]) key = NO; }
    @synchronized (g_sizes) { [g_sizes addObject:@(CMSampleBufferGetTotalSampleSize(sb))]; [g_idr addObject:@(key)]; }
}
static CVPixelBufferRef make_frame(int w, int h, int i)
{
    CVPixelBufferRef pb = NULL; CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &pb);
    CVPixelBufferLockBaseAddress(pb, 0); uint8_t *Y = CVPixelBufferGetBaseAddressOfPlane(pb, 0); size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {   // moving texture: gradient + checker + hashed noise that shifts 2 px/frame
        unsigned n = (unsigned)((x + 2 * i) * 2654435761u ^ (unsigned)y * 40503u); n ^= n >> 13; int noise = (int)(n & 31) - 16;
        int v = 60 + ((x + 3 * i) * 120) / w + 30 * ((((x + 2 * i) / 24) + (y / 24)) & 1) + noise; Y[y * ys + x] = (uint8_t)(v < 16 ? 16 : v > 235 ? 235 : v); }
    uint8_t *C = CVPixelBufferGetBaseAddressOfPlane(pb, 1); size_t cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int y = 0; y < h / 2; y++) for (int x = 0; x < w / 2; x++) { C[y * cs + 2 * x] = 110 + (x * 30) / (w / 2); C[y * cs + 2 * x + 1] = 120 + ((y + i) & 7); }
    CVPixelBufferUnlockBaseAddress(pb, 0); return pb;
}
// One session: create, encode N frames with AverageBitRate set, release. Returns the mean bitrate (Mbit/s) after the first
// second, or -1 when the session could not be created.
static double run_session(int W, int H, int N, double fps, double target, int show)
{
    @autoreleasepool {
    [g_sizes removeAllObjects]; [g_idr removeAllObjects];
    VTCompressionSessionRef cs = NULL;
    OSStatus st = VTCompressionSessionCreate(NULL, W, H, g_codec, (__bridge CFDictionaryRef)@{ (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES, @"EnableLowLatencyRateControl": @YES }, NULL, NULL, out_cb, NULL, &cs);
    if (!cs) { printf("create failed %d (BAR1 window full? other GPU apps running?)\n", (int)st); return -1; }
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue); VTSessionSetProperty(cs, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@100000); VTSessionSetProperty(cs, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(fps));
    if (target > 0) VTSessionSetProperty(cs, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(target));
    VTCompressionSessionPrepareToEncodeFrames(cs);
    for (int i = 0; i < N; i++) { CVPixelBufferRef pb = make_frame(W, H, i); VTCompressionSessionEncodeFrame(cs, pb, CMTimeMake(i, (int32_t)fps), CMTimeMake(1, (int32_t)fps), NULL, NULL, NULL); CFRelease(pb); usleep(4000); }
    VTCompressionSessionCompleteFrames(cs, kCMTimeInvalid);
    NSUInteger n = g_sizes.count; if (show) printf("frames out %lu of %d; target %.2f Mbit/s\n", (unsigned long)n, N, target / 1e6);
    double total = 0; int cnt = 0; if (show) printf("per second (Mbit/s):");
    for (NSUInteger s0 = 0; s0 + 60 <= n; s0 += 60) { double b = 0; for (NSUInteger i = s0; i < s0 + 60; i++) b += [g_sizes[i] doubleValue]; if (show) printf(" %.1f", b * 8 / 1e6); if (s0 >= 60) { total += b * 8 / 1e6; cnt++; } }
    if (show) printf("\n");
    VTCompressionSessionInvalidate(cs); CFRelease(cs);
    // A bitrate mean is not a passing result if the encoder lost frames.
    return n == (NSUInteger)N && cnt ? total / cnt : -1; }
}
int main(int argc, char **argv) { @autoreleasepool {
    double target = argc > 1 ? atof(argv[1]) : 0; int N = argc > 2 ? atoi(argv[2]) : 360, S = argc > 3 ? atoi(argv[3]) : 1, W = 1280, H = 720; const double fps = 60;
    const char *codec = getenv("PROBE_CODEC");
    if (codec && !strcmp(codec, "hevc")) g_codec = kCMVideoCodecType_HEVC;
    else if (codec && strcmp(codec, "h264")) { fprintf(stderr, "PROBE_CODEC must be h264 or hevc\n"); return 2; }
    if (N < 120 || S < 1 || !isfinite(target) || target < 0) { fprintf(stderr, "need at least 120 frames, one session and a nonnegative finite target\n"); return 2; }
    printf("codec: %s\n", g_codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264");
    g_sizes = [NSMutableArray array]; g_idr = [NSMutableArray array];
    nvmtl_vt_spec_hook_install();                                  // the hook under test, in this process
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); (void)dev; usleep(300000);
    int bad = 0;
    for (int k = 0; k < S; k++) {
        const double m = run_session(W, H, N, fps, target, S == 1);
        if (m < 0) _exit(2);
        const int off = target > 0 && fabs(m * 1e6 - target) > 0.25 * target;
        bad += off;  // enforce the same window for one session and repeated sessions
        if (S > 1) {
            printf("session %d of %d: mean %.2f Mbit/s (target %.2f)%s\n", k + 1, S, m, target / 1e6, off ? "  OUT OF WINDOW" : "");
        } else printf("after the first second: mean %.2f Mbit/s\n", m);
    }
    fflush(stdout); _exit(bad ? 1 : 0); } }
