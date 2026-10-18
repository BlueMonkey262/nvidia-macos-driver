// nvenc_psnr: encode synthetic NV12 frames with VideoToolbox H.264 (hardware required), decode them again with Apple's
// software decoder and compare with the source. A correct picture is ~42 dB or more; a wrongly tiled one is 17-28 dB.
// usage: nvenc_psnr [width height frames [min_psnr_db]]       default 1280 720 30 40
//        nvenc_psnr --overlap [width height]                  open a second session before closing the first (what
//                                                             Sunshine does); each session must emit frames
// exit: 0 pass, 2 no hardware session, 3 nothing encoded, 4 no decoder, 5 PSNR below the threshold or frames lost,
//       6 session is not hardware, 7 an overlapping session emitted nothing
// build: clang -fobjc-arc -O1 -o nvenc_psnr nvenc_psnr.m -framework Foundation -framework VideoToolbox \
//          -framework CoreMedia -framework CoreVideo -framework Metal
// Set NVMTL_NO_NVDEC=1 so the same software decoder checks every run.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>
#include <math.h>

typedef struct { NSMutableArray *samples; int errors; } enc_ctx;

static CVPixelBufferRef make_frame(int w, int h, int i)
{
    CVPixelBufferRef pb = NULL;
    NSDictionary *attr = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)attr, &pb)) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *Y = CVPixelBufferGetBaseAddressOfPlane(pb, 0); size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int v = 40 + (((x + 4 * i) % w) * 150) / w + 30 * ((((x + 2 * i) / 32) + (y / 32)) & 1) + (((x * y) >> 9) & 15);
        Y[y * ys + x] = (uint8_t)(v > 235 ? 235 : v);
    }
    uint8_t *C = CVPixelBufferGetBaseAddressOfPlane(pb, 1); size_t cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int y = 0; y < h / 2; y++) for (int x = 0; x < w / 2; x++) {
        C[y * cs + 2 * x] = (uint8_t)(108 + (x * 40) / (w / 2));
        C[y * cs + 2 * x + 1] = (uint8_t)(108 + (y * 40) / (h / 2));
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static double psnr_plane(CVPixelBufferRef a, CVPixelBufferRef b, int plane, int width_bytes)
{
    uint8_t *pa = CVPixelBufferGetBaseAddressOfPlane(a, plane), *pb = CVPixelBufferGetBaseAddressOfPlane(b, plane);
    size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, plane), sb = CVPixelBufferGetBytesPerRowOfPlane(b, plane);
    size_t rows = CVPixelBufferGetHeightOfPlane(a, plane);
    double se = 0; size_t n = 0;
    for (size_t y = 0; y < rows; y++) for (int x = 0; x < width_bytes; x++) {
        double d = (double)pa[y * sa + x] - (double)pb[y * sb + x]; se += d * d; n++;
    }
    return se == 0 ? 99.0 : 10.0 * log10(255.0 * 255.0 / (se / n));
}

static void enc_cb(void *refcon, void *src, OSStatus status, VTEncodeInfoFlags f, CMSampleBufferRef sb)
{
    enc_ctx *c = refcon;
    @synchronized (c->samples) { if (status || !sb) c->errors++; else [c->samples addObject:(__bridge id)sb]; }
}

static VTCompressionSessionRef open_session(int w, int h, enc_ctx *c, OSStatus *st)
{
    NSDictionary *spec = @{ (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES };
    VTCompressionSessionRef cs = NULL;
    *st = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_H264, (__bridge CFDictionaryRef)spec, NULL, NULL, enc_cb, c, &cs);
    if (!cs) return NULL;
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@30);
    VTCompressionSessionPrepareToEncodeFrames(cs);
    return cs;
}

static bool session_is_hardware(VTCompressionSessionRef cs)
{
    CFBooleanRef hw = NULL;
    VTSessionCopyProperty(cs, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, (void *)&hw);
    bool yes = hw && CFBooleanGetValue(hw);
    if (hw) CFRelease(hw);
    return yes;
}

static void encode_n(VTCompressionSessionRef cs, NSArray *src, int n, int *encode_errors)
{
    for (int i = 0; i < n; i++) {
        OSStatus e = VTCompressionSessionEncodeFrame(cs, (__bridge CVPixelBufferRef)src[i], CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
        if (e) { printf("EncodeFrame %d -> %d\n", i, (int)e); (*encode_errors)++; }
    }
    VTCompressionSessionCompleteFrames(cs, kCMTimeInvalid);
}

static int run_overlap(int w, int h)
{
    enum { N = 5 };
    NSMutableArray *src = [NSMutableArray array];
    for (int i = 0; i < N; i++) [src addObject:(__bridge_transfer id)make_frame(w, h, i)];
    enc_ctx a = { [NSMutableArray array], 0 }, b = { [NSMutableArray array], 0 };
    OSStatus sa, sb; int ee = 0;
    VTCompressionSessionRef A = open_session(w, h, &a, &sa);
    printf("overlap: session A create %d, hardware %s\n", (int)sa, A && session_is_hardware(A) ? "yes" : "no");
    VTCompressionSessionRef B = open_session(w, h, &b, &sb);                 // A is still open
    printf("overlap: session B create %d, hardware %s\n", (int)sb, B && session_is_hardware(B) ? "yes" : "no");
    if (A) encode_n(A, src, N, &ee);
    if (B) encode_n(B, src, N, &ee);
    printf("overlap: A emitted %lu of %d, B emitted %lu of %d, encoder errors %d\n", (unsigned long)a.samples.count, N, (unsigned long)b.samples.count, N, a.errors + b.errors + ee);
    if (A) VTCompressionSessionInvalidate(A);
    if (B) VTCompressionSessionInvalidate(B);
    return (a.samples.count == N && b.samples.count == N && !a.errors && !b.errors && !ee) ? 0 : 7;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        bool overlap = argc > 1 && !strcmp(argv[1], "--overlap");
        int ai = overlap ? 2 : 1;
        int w = argc > ai ? atoi(argv[ai]) : 1280, h = argc > ai + 1 ? atoi(argv[ai + 1]) : 720;
        int n = !overlap && argc > 3 ? atoi(argv[3]) : 30;
        double min_db = !overlap && argc > 4 ? atof(argv[4]) : 40.0;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();     // brings the driver plugin up, which registers NVENC here
        printf("Metal device: %s\n", dev ? dev.name.UTF8String : "(none)");
        usleep(300000);
        if (overlap) return run_overlap(w, h);

        NSMutableArray *src = [NSMutableArray array];
        for (int i = 0; i < n; i++) [src addObject:(__bridge_transfer id)make_frame(w, h, i)];

        enc_ctx c = { [NSMutableArray array], 0 };
        OSStatus st;
        VTCompressionSessionRef cs = open_session(w, h, &c, &st);
        if (!cs) { printf("VTCompressionSessionCreate with a hardware requirement failed: %d\n", (int)st); return 2; }
        bool hw = session_is_hardware(cs);
        printf("UsingHardwareAcceleratedVideoEncoder: %s\n", hw ? "yes" : "no");
        double t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
        int ee = 0;
        encode_n(cs, src, n, &ee);
        double ms = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6 - t0;
        VTCompressionSessionInvalidate(cs);
        c.errors += ee;
        printf("encoded samples: %lu of %d, encoder errors: %d, %.2f ms/frame wall\n", (unsigned long)c.samples.count, n, c.errors, ms / n);
        if (!c.samples.count) return 3;
        if (!hw) return 6;

        size_t bytes = 0;
        for (id s in c.samples) bytes += CMSampleBufferGetTotalSampleSize((__bridge CMSampleBufferRef)s);
        printf("bitrate: %.2f Mbit/s at 30 fps\n", bytes * 8.0 / ((double)c.samples.count / 30.0) / 1e6);

        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)c.samples[0]);
        NSDictionary *dspec = @{ (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @NO };
        NSDictionary *dattr = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
        VTDecompressionSessionRef ds = NULL;
        if (VTDecompressionSessionCreate(NULL, fd, (__bridge CFDictionaryRef)dspec, (__bridge CFDictionaryRef)dattr, NULL, &ds) || !ds) {
            printf("decoder create failed\n"); return 4;
        }
        __block int idx = 0; __block double sumY = 0, minY = 99, sumC = 0;
        for (id s in c.samples) {
            VTDecompressionSessionDecodeFrameWithOutputHandler(ds, (__bridge CMSampleBufferRef)s, 0, NULL,
                ^(OSStatus status, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
                    if (status || !img) { printf("decode error %d\n", (int)status); return; }
                    int i = (int)pts.value; if (i < 0 || i >= n) return;
                    CVPixelBufferRef a = (__bridge CVPixelBufferRef)src[i];
                    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
                    double py = psnr_plane(a, img, 0, w), pc = psnr_plane(a, img, 1, w);
                    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
                    sumY += py; sumC += pc; if (py < minY) minY = py; idx++;
                });
        }
        VTDecompressionSessionWaitForAsynchronousFrames(ds);
        VTDecompressionSessionInvalidate(ds);
        printf("decoded %d frames: mean Y PSNR %.1f dB (min %.1f), mean UV %.1f dB\n", idx, idx ? sumY / idx : 0, minY, idx ? sumC / idx : 0);
        bool ok = idx == n && c.errors == 0 && (int)c.samples.count == n && sumY / (idx ? idx : 1) >= min_db && minY >= min_db;
        printf("%s (threshold %.1f dB on mean and minimum)\n", ok ? "PASS" : "FAIL", min_db);
        return ok ? 0 : 5;
    }
}
