// nvenc_psnr_hevc: encode synthetic NV12 frames with VideoToolbox HEVC (hardware required), decode them again with
// Apple's software decoder and compare with the source. A correct picture is ~42 dB or more; a wrongly tiled one is
// 17-28 dB. Same frames, sizes and exit codes as tools/nvenc_psnr.m. 1366 is not a multiple of 16; the library aligns
// the coded size to 32. Not run on a GPU.
// usage: nvenc_psnr_hevc [width height frames [min_psnr_db]]  default 1280 720 30 40
//        nvenc_psnr_hevc --props-open [width height]          open a session, then look up the encoder's supported properties
//                                                             with it still open (what ffmpeg does)
//        nvenc_psnr_hevc --overlap [width height]             open a second session before closing the first (what
//                                                             Sunshine does); each session must emit frames
// exit: 0 pass, 2 no hardware session, 3 nothing encoded, 4 no decoder, 5 PSNR below the threshold or frames lost,
//       6 session is not hardware, 7 an overlapping session emitted nothing, 8 the property lookup failed
// build: clang -fobjc-arc -O1 -o nvenc_psnr_hevc nvenc_psnr_hevc.m -framework Foundation -framework VideoToolbox \
//          -framework CoreMedia -framework CoreVideo -framework Metal
// Set NVMTL_NVENC_HEVC=1 so Turing registers the encoder, and NVMTL_NO_NVDEC_HEVC=1 so the same software decoder checks
// every run (NVMTL_NO_NVDEC does not cover HEVC). NVENC_PSNR_LOW_LATENCY=1 adds EnableLowLatencyRateControl to the
// encoder specification, as ffmpeg/Sunshine do. NVENC_PSNR_DUMP=file writes the encoded stream as Annex B (VPS, SPS
// and PPS before every key frame) so tools/hevc_refs.py can check it.
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
    NSMutableDictionary *spec = [@{ (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES } mutableCopy];
    // ffmpeg's hevc_videotoolbox (so Sunshine) adds this key in low-delay mode; set NVENC_PSNR_LOW_LATENCY=1 to do the same
    if (getenv("NVENC_PSNR_LOW_LATENCY")) spec[(id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = @YES;
    VTCompressionSessionRef cs = NULL;
    *st = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_HEVC, (__bridge CFDictionaryRef)spec, NULL, NULL, enc_cb, c, &cs);
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

static void write_annexb(const char *path, NSArray *samples)
{
    FILE *out = fopen(path, "wb");
    if (!out) { printf("cannot write %s\n", path); exit(9); }   // a missing dump must not look like a pass
    static const uint8_t sc[3] = {0, 0, 1};
    for (id s in samples) {
        CMSampleBufferRef sb = (__bridge CMSampleBufferRef)s;
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
        CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
        CFDictionaryRef a0 = att && CFArrayGetCount(att) ? CFArrayGetValueAtIndex(att, 0) : NULL;
        bool key = !(a0 && CFDictionaryContainsKey(a0, kCMSampleAttachmentKey_NotSync) &&
                     CFBooleanGetValue(CFDictionaryGetValue(a0, kCMSampleAttachmentKey_NotSync)));
        size_t count = 0; int nal_len = 4; const uint8_t *ps; size_t psn;
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, &ps, &psn, &count, &nal_len);
        if (key) {
            static int reported;
            if (!reported) { printf("HEVC parameter sets before first key frame: %zu\n", count); reported = 1; }
        }
        for (size_t i = 0; key && i < count; i++) {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &ps, &psn, NULL, NULL);
            fwrite(sc, 1, 3, out); fwrite(ps, 1, psn, out);
        }
        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
        if (!bb) continue;
        size_t len = CMBlockBufferGetDataLength(bb), pos = 0;
        uint8_t *d = malloc(len ? len : 1);
        if (!d || CMBlockBufferCopyDataBytes(bb, 0, len, d)) { free(d); continue; }
        while (pos + nal_len <= len) {
            uint32_t n = 0;
            for (int k = 0; k < nal_len; k++) n = (n << 8) | d[pos + k];
            pos += nal_len;
            if (n == 0 || pos + n > len) break;
            fwrite(sc, 1, 3, out); fwrite(d + pos, 1, n, out); pos += n;
        }
        free(d);
    }
    fclose(out);
    printf("wrote Annex B stream to %s\n", path);
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

static int run_props_open(int w, int h)
{
    enc_ctx a = { [NSMutableArray array], 0 };
    OSStatus sa;
    VTCompressionSessionRef A = open_session(w, h, &a, &sa);
    printf("props-open: session create %d, hardware %s\n", (int)sa, A && session_is_hardware(A) ? "yes" : "no");
    // what ffmpeg does next, with no encoder-ID output and the session still open
    NSDictionary *spec = @{ (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES };
    CFDictionaryRef props = NULL;
    OSStatus sp = VTCopySupportedPropertyDictionaryForEncoder(w, h, kCMVideoCodecType_HEVC, (__bridge CFDictionaryRef)spec, NULL, &props);
    printf("props-open: VTCopySupportedPropertyDictionaryForEncoder with a session open -> %d (%ld keys)\n", (int)sp, props ? (long)CFDictionaryGetCount(props) : -1L);
    if (props) CFRelease(props);
    if (A) VTCompressionSessionInvalidate(A);
    return (A && sp == 0 && props) ? 0 : 8;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        bool overlap = argc > 1 && !strcmp(argv[1], "--overlap");
        bool propsopen = argc > 1 && !strcmp(argv[1], "--props-open");
        int ai = (overlap || propsopen) ? 2 : 1;
        int w = argc > ai ? atoi(argv[ai]) : 1280, h = argc > ai + 1 ? atoi(argv[ai + 1]) : 720;
        int n = !overlap && !propsopen && argc > 3 ? atoi(argv[3]) : 30;
        double min_db = !overlap && !propsopen && argc > 4 ? atof(argv[4]) : 40.0;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();     // brings the driver plugin up, which registers NVENC here
        printf("Metal device: %s\n", dev ? dev.name.UTF8String : "(none)");
        usleep(300000);
        if (overlap) return run_overlap(w, h);
        if (propsopen) return run_props_open(w, h);

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
        if (getenv("NVENC_PSNR_DUMP")) write_annexb(getenv("NVENC_PSNR_DUMP"), c.samples);

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
