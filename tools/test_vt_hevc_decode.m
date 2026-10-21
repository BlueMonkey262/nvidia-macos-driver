// test_vt_hevc_decode: check hardware HEVC decode through VideoToolbox on this driver.
// A deterministic 4:2:0 pattern (edges, gradient, noise) is encoded by a software HEVC encoder, then decoded twice:
// once requiring hardware decode and once forcing software decode. Each size runs 30 frames. 1920x1080 is the main
// picture; 1280x144 stays under 256 rows and takes a different decoder path. Main10 is the same test at 10-bit.
// Hardware PSNR has to be within 1.5 dB of software PSNR and at least 38 dB on luma and chroma, every frame,
// against the source and between the two decoded pictures.
// usage: test_vt_hevc_decode
// exit: 0 pass, 1 fail, 77 Main10 skipped (8-bit passed; the software encoder or the hardware decoder refused Main10)
// build: clang -fobjc-arc -O1 -o test_vt_hevc_decode tools/test_vt_hevc_decode.m -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo
// Sets NVMTL_NO_NVENC_HEVC=1 and EnableHardwareAcceleratedVideoEncoder=false, and pins EncoderID when the list has a
// non-hardware HEVC encoder, so the bitstream is not produced by this driver's encoder. Leave NVMTL_NO_NVDEC_HEVC unset.
// A wrong Blackwell untiling mode shows up as 128x32-tile scrambling. Not run on a GPU here.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { kFrames = 30, kTileW = 128, kTileH = 32 };

typedef struct {
    uint16_t *y;          // w * h samples, 8-bit or normalized 10-bit (0..1023)
    uint16_t *c;          // (w/2)*(h/2)*2 interleaved Cb,Cr samples
    int w, h, ten, shift; // shift is the 16-bit container alignment seen on a decoded 10-bit buffer (6 = MSB)
} pic;

typedef struct {
    CMSampleBufferRef samples[kFrames];
    int n, errors, got;
    pthread_mutex_t *mu;
} enc_box;

typedef struct {
    pic *frames[kFrames];
    int n, w, h, ten, errors, got;
    pthread_mutex_t *mu;
    char why[160];
} dec_box;

static const char *yesno(int v) { return v < 0 ? "unknown" : v ? "yes" : "no"; }

static uint32_t mix(uint32_t x)
{
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
}

static void fourcc(OSType t, char out[5])
{
    out[0] = (char)((t >> 24) & 0xff); out[1] = (char)((t >> 16) & 0xff);
    out[2] = (char)((t >> 8) & 0xff); out[3] = (char)(t & 0xff); out[4] = 0;
    for (int i = 0; i < 4; i++) if ((unsigned char)out[i] < 32 || (unsigned char)out[i] > 126) out[i] = '?';
}

static pic *pic_new(int w, int h, int ten)
{
    pic *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->w = w; p->h = h; p->ten = ten; p->shift = ten ? 6 : 0;
    p->y = calloc((size_t)w * (size_t)h, sizeof(uint16_t));
    p->c = calloc((size_t)(w / 2) * (size_t)(h / 2) * 2, sizeof(uint16_t));
    if (!p->y || !p->c) { free(p->y); free(p->c); free(p); return NULL; }
    return p;
}

static void pic_free(pic *p) { if (!p) return; free(p->y); free(p->c); free(p); }

static int luma8(int x, int y, int w, int h, int frame)
{
    uint32_t n = mix((uint32_t)x * 2654435761u ^ (uint32_t)y * 2246822519u ^ (uint32_t)frame * 40503u);
    int edge = (x % 128 == 0) || (y % 32 == 0) || (x % 64 == 3) || (y % 16 == 5);
    int bar = ((x + frame * 13) % w) < 4;
    int grad = 16 + (x * 150) / w + (y * 60) / h;
    int v = bar ? 220 : edge ? 200 : grad + (int)(n & 31) - 8 + ((((x + y) / 17) & 1) ? 18 : 0);
    if (v < 16) v = 16;
    if (v > 235) v = 235;
    return v;
}

static int chroma8(int x, int y, int cw, int ch, int frame, int cr)
{
    uint32_t n = mix((uint32_t)x * 374761393u ^ (uint32_t)y * 668265263u ^ (uint32_t)frame * 1274126177u ^ (uint32_t)cr * 2246822519u);
    int edge = (x % 64 == 0) || (y % 16 == 0);
    int grad = cr ? 16 + (y * 180) / ch : 16 + (x * 180) / cw;
    int v = edge ? 210 : grad + (int)(n & 15) - 4;
    if (v < 16) v = 16;
    if (v > 240) v = 240;
    return v;
}

static int to_ten_luma(int v8, uint32_t n)
{
    int v = 64 + (v8 - 16) * (940 - 64) / (235 - 16) + (int)(n & 3);
    if (v < 64) v = 64;
    if (v > 940) v = 940;
    return v;
}

static int to_ten_chroma(int v8, uint32_t n)
{
    int v = 64 + (v8 - 16) * (960 - 64) / (240 - 16) + (int)((n >> 2) & 3);
    if (v < 64) v = 64;
    if (v > 960) v = 960;
    return v;
}

// Edges sit on the 128x32 grid and off it, so a tile swap cannot land back on the same edges. The moving bar and
// per-frame noise give the P-frames something to code. 10-bit keeps two hash bits under the 8-bit shape.
static void fill_pattern(pic *p, int frame)
{
    for (int y = 0; y < p->h; y++) for (int x = 0; x < p->w; x++) {
        int v = luma8(x, y, p->w, p->h, frame);
        if (p->ten) v = to_ten_luma(v, mix((uint32_t)x * 1597334677u ^ (uint32_t)y * 3812015801u ^ (uint32_t)frame));
        p->y[y * p->w + x] = (uint16_t)v;
    }
    int cw = p->w / 2, ch = p->h / 2;
    for (int y = 0; y < ch; y++) for (int x = 0; x < cw; x++) {
        int cb = chroma8(x, y, cw, ch, frame, 0), cr = chroma8(x, y, cw, ch, frame, 1);
        if (p->ten) {
            uint32_t n = mix((uint32_t)x * 747796405u ^ (uint32_t)y * 2891336453u ^ (uint32_t)frame * 37u);
            cb = to_ten_chroma(cb, n); cr = to_ten_chroma(cr, n ^ 0x9e3779b9u);
        }
        p->c[(y * cw + x) * 2] = (uint16_t)cb;
        p->c[(y * cw + x) * 2 + 1] = (uint16_t)cr;
    }
}

static void put_sample(uint8_t *dst, int ten, int value)
{
    if (!ten) { dst[0] = (uint8_t)value; return; }
    uint16_t w = (uint16_t)(value << 6); // x420 / P010: 10 bits in the high end of the uint16
    memcpy(dst, &w, 2);
}

static int get_sample(const uint8_t *src, int ten, int shift)
{
    if (!ten) return src[0];
    uint16_t w; memcpy(&w, src, 2);
    return (w >> shift) & 0x3ff;
}

static void tag_color(CVPixelBufferRef pb)
{
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
}

static CVPixelBufferRef pb_from_pic(const pic *p)
{
    OSType fmt = p->ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    NSDictionary *attr = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, p->w, p->h, fmt, (__bridge CFDictionaryRef)attr, &pb) || !pb) return NULL;
    if (CVPixelBufferLockBaseAddress(pb, 0)) { CFRelease(pb); return NULL; }
    int sb = p->ten ? 2 : 1;
    size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    if (ybpr < (size_t)p->w * sb || cbpr < (size_t)p->w * sb || CVPixelBufferGetPlaneCount(pb) < 2) {
        CVPixelBufferUnlockBaseAddress(pb, 0); CFRelease(pb); return NULL;
    }
    uint8_t *ybase = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *cbase = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    for (int y = 0; y < p->h; y++) for (int x = 0; x < p->w; x++)
        put_sample(ybase + y * ybpr + x * sb, p->ten, p->y[y * p->w + x]);
    int csamp = (p->w / 2) * 2;
    for (int y = 0; y < p->h / 2; y++) for (int x = 0; x < csamp; x++)
        put_sample(cbase + y * cbpr + x * sb, p->ten, p->c[y * csamp + x]);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    tag_color(pb);
    return pb;
}

// High bits set => MSB-aligned 10-bit (what we encode). All high bits clear => LSB-aligned decoder output.
static int tenbit_shift(CVPixelBufferRef pb)
{
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t h = CVPixelBufferGetHeightOfPlane(pb, 0), w = CVPixelBufferGetWidthOfPlane(pb, 0);
    uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    for (size_t y = 0; y < h; y += 16) {
        for (size_t x = 0; x < w; x += 16) {
            uint16_t v; memcpy(&v, base + y * stride + x * 2, 2);
            if (v & 0xfc00) return 6;
        }
    }
    return 0;
}

static pic *pic_from_pb(CVPixelBufferRef pb, int w, int h, int ten, char *why, size_t whyn)
{
    OSType want = ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    OSType got = CVPixelBufferGetPixelFormatType(pb);
    size_t planes = CVPixelBufferGetPlaneCount(pb);
    if (got != want || CVPixelBufferGetWidth(pb) != (size_t)w || CVPixelBufferGetHeight(pb) != (size_t)h || planes < 2 ||
        CVPixelBufferGetHeightOfPlane(pb, 0) != (size_t)h || CVPixelBufferGetHeightOfPlane(pb, 1) != (size_t)(h / 2)) {
        char a[5], b[5]; fourcc(got, a); fourcc(want, b);
        snprintf(why, whyn, "picture %dx%d %.4s (%zu planes), wanted %dx%d %.4s",
                 (int)CVPixelBufferGetWidth(pb), (int)CVPixelBufferGetHeight(pb), a, planes, w, h, b);
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly)) {
        snprintf(why, whyn, "CVPixelBufferLockBaseAddress failed"); return NULL;
    }
    int shift = ten ? tenbit_shift(pb) : 0;
    int sb = ten ? 2 : 1;
    size_t ybpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cbpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    if (ybpr < (size_t)w * sb || cbpr < (size_t)w * sb) {
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        snprintf(why, whyn, "plane stride too small"); return NULL;
    }
    pic *p = pic_new(w, h, ten);
    if (!p) {
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        snprintf(why, whyn, "out of memory"); return NULL;
    }
    p->shift = shift;
    uint8_t *ybase = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *cbase = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
        p->y[y * w + x] = (uint16_t)get_sample(ybase + y * ybpr + x * sb, ten, shift);
    int csamp = (w / 2) * 2;
    for (int y = 0; y < h / 2; y++) for (int x = 0; x < csamp; x++)
        p->c[y * csamp + x] = (uint16_t)get_sample(cbase + y * cbpr + x * sb, ten, shift);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return p;
}

static int session_bool(void *session, CFStringRef key)
{
    CFTypeRef v = NULL;
    if (!session || VTSessionCopyProperty((VTSessionRef)session, key, NULL, &v) || !v) return -1;
    int r = -1;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue(v) ? 1 : 0;
    CFRelease(v);
    return r;
}

static NSString *session_string(void *session, CFStringRef key)
{
    CFTypeRef v = NULL;
    if (!session || VTSessionCopyProperty((VTSessionRef)session, key, NULL, &v) || !v) return nil;
    NSString *s = nil;
    CFTypeID kind = CFGetTypeID(v);
    if (kind == CFStringGetTypeID()) s = [NSString stringWithString:(__bridge NSString *)v];
    else if (kind == CFNumberGetTypeID()) {
        long n = 0; CFNumberGetValue(v, kCFNumberLongType, &n); s = [NSString stringWithFormat:@"%ld", n];
    }
    CFRelease(v);
    return s;
}

static NSString *decoder_ident(VTDecompressionSessionRef ds)
{
    // DecoderID is not in the public headers this tree includes; ask for the names VT has been seen to answer.
    static const char *keys[] = { "DecoderID", "VideoDecoderID", "CMClassImplementationID" };
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        NSString *s = session_string(ds, (__bridge CFStringRef)@(keys[i]));
        if (s.length) return [NSString stringWithFormat:@"%s=%@", keys[i], s];
    }
    return @"unavailable";
}

static int driver_encoder(NSString *s)
{
    if (!s) return 0;
    NSString *l = s.lowercaseString;
    return [l containsString:@"nvmtl"] || [l containsString:@"nvenc"] || [l containsString:@"nvidia"];
}

static NSString *pick_software_encoder(void)
{
    CFArrayRef list = NULL;
    OSStatus st = VTCopyVideoEncoderList(NULL, &list);
    if (st || !list) { printf("VTCopyVideoEncoderList -> %d\n", (int)st); return nil; }
    NSString *fallback = nil, *preferred = nil;
    printf("HEVC encoders:\n");
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) continue;
        CFNumberRef ct = CFDictionaryGetValue(d, kVTVideoEncoderList_CodecType);
        int codec = 0;
        if (!ct || !CFNumberGetValue(ct, kCFNumberSInt32Type, &codec) || codec != kCMVideoCodecType_HEVC) continue;
        CFStringRef eid = CFDictionaryGetValue(d, kVTVideoEncoderList_EncoderID);
        NSString *ident = eid && CFGetTypeID(eid) == CFStringGetTypeID() ? [NSString stringWithString:(__bridge NSString *)eid] : nil;
        CFTypeRef hwv = CFDictionaryGetValue(d, kVTVideoEncoderList_IsHardwareAccelerated);
        int hw = -1;
        if (hwv && CFGetTypeID(hwv) == CFBooleanGetTypeID()) hw = CFBooleanGetValue(hwv) ? 1 : 0;
        CFStringRef name = CFDictionaryGetValue(d, kVTVideoEncoderList_DisplayName);
        printf("  %s hardware=%s name=%s\n", ident.UTF8String ?: "(none)", yesno(hw),
               (name && CFGetTypeID(name) == CFStringGetTypeID()) ? ((__bridge NSString *)name).UTF8String : "(none)");
        if (!ident || driver_encoder(ident) || hw == 1) continue;
        NSString *low = ident.lowercaseString;
        int says_sw = [low containsString:@"software"] || [low containsString:@".sw"];
        if (hw == 0 && !fallback) fallback = ident;
        if ((hw == 0 || hw < 0) && says_sw) preferred = ident;
    }
    CFRelease(list);
    NSString *chosen = preferred ? preferred : fallback;
    printf("software encoder: %s\n", chosen ? chosen.UTF8String : "(none listed; EnableHardwareAcceleratedVideoEncoder=false only)");
    return chosen;
}

// SPS NAL (type 33) carries general_profile_idc in the low 5 bits of byte 3. Main is 1, Main10 is 2.
static int hevc_profile_idc(CMFormatDescriptionRef fd)
{
    size_t count = 0; const uint8_t *ps = NULL; size_t psn = 0; int nal_len = 4;
    if (!fd || CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, &ps, &psn, &count, &nal_len)) return -1;
    for (size_t i = 0; i < count; i++) {
        if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &ps, &psn, NULL, NULL) || psn < 4) continue;
        if (((ps[0] >> 1) & 0x3f) != 33) continue;
        return ps[3] & 0x1f;
    }
    return -1;
}

static double plane_psnr(const uint16_t *a, const uint16_t *b, int n, int peak, int *max_abs)
{
    double se = 0; int mx = 0;
    for (int i = 0; i < n; i++) {
        int d = (int)a[i] - (int)b[i]; if (d < 0) d = -d;
        if (d > mx) mx = d; se += (double)d * (double)d;
    }
    if (max_abs && mx > *max_abs) *max_abs = mx;
    if (n <= 0) return 0;
    if (se == 0) return 99.0;
    return 10.0 * log10((double)peak * (double)peak / (se / n));
}

static int rect_max(const uint16_t *a, const uint16_t *b, int stride, int x, int y, int tw, int th)
{
    int mx = 0;
    for (int row = 0; row < th; row++) {
        const uint16_t *pa = a + (size_t)(y + row) * stride + x;
        const uint16_t *pb = b + (size_t)(y + row) * stride + x;
        for (int col = 0; col < tw; col++) {
            int d = (int)pa[col] - (int)pb[col]; if (d < 0) d = -d;
            if (d > mx) mx = d;
        }
    }
    return mx;
}

static double rect_mean(const uint16_t *a, const uint16_t *b, int stride, int x, int y, int tw, int th)
{
    double s = 0;
    for (int row = 0; row < th; row++) {
        const uint16_t *pa = a + (size_t)(y + row) * stride + x;
        const uint16_t *pb = b + (size_t)(y + row) * stride + x;
        for (int col = 0; col < tw; col++) {
            int d = (int)pa[col] - (int)pb[col]; if (d < 0) d = -d;
            s += d;
        }
    }
    return tw > 0 && th > 0 ? s / (tw * th) : 0;
}

static double residual_corr(const uint16_t *a, const uint16_t *b, int w, int h, int dx, int dy)
{
    if (dx < 0 || dy < 0 || dx >= w || dy >= h) return 0;
    double s0 = 0, s1 = 0, s00 = 0, s11 = 0, s01 = 0; long n = 0;
    for (int y = 0; y < h - dy; y += 2) for (int x = 0; x < w - dx; x += 2) {
        double r0 = (double)a[y * w + x] - (double)b[y * w + x];
        double r1 = (double)a[(y + dy) * w + (x + dx)] - (double)b[(y + dy) * w + (x + dx)];
        s0 += r0; s1 += r1; s00 += r0 * r0; s11 += r1 * r1; s01 += r0 * r1; n++;
    }
    if (n < 16) return 0;
    double v0 = s00 - s0 * s0 / n, v1 = s11 - s1 * s1 / n, cov = s01 - s0 * s1 / n;
    if (v0 < 1e-6 || v1 < 1e-6) return 0;
    return cov / sqrt(v0 * v1);
}

static void enc_cb(void *refcon, void *source, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb)
{
    (void)flags;
    enc_box *c = refcon;
    pthread_mutex_lock(c->mu);
    intptr_t i = (intptr_t)source - 1; // EncodeFrame is given index+1 so frame 0 is not a NULL refcon
    if (status || !sb || i < 0 || i >= c->n || c->samples[i]) c->errors++;
    else { c->samples[i] = (CMSampleBufferRef)CFRetain(sb); c->got++; }
    pthread_mutex_unlock(c->mu);
}

static void dec_store(dec_box *c, OSStatus status, CVImageBufferRef image, CMTime pts)
{
    if (status || !image || !CMTIME_IS_NUMERIC(pts)) {
        pthread_mutex_lock(c->mu);
        c->errors++;
        if (!c->why[0]) snprintf(c->why, sizeof c->why, "decode status %d", (int)status);
        pthread_mutex_unlock(c->mu);
        return;
    }
    // Integer rounding stays exact when the encoder keeps the 1/30 timestamps we submitted.
    int i = (int)((pts.value * 30 + pts.timescale / 2) / pts.timescale);
    char why[160] = {0};
    pic *p = (i >= 0 && i < c->n) ? pic_from_pb(image, c->w, c->h, c->ten, why, sizeof why) : NULL;
    pthread_mutex_lock(c->mu);
    if (i < 0 || i >= c->n || c->frames[i] || !p) {
        c->errors++;
        if (!c->why[0]) snprintf(c->why, sizeof c->why, "%s", why[0] ? why : "bad decode timestamp or duplicate frame");
        pic_free(p);
    } else { c->frames[i] = p; c->got++; }
    pthread_mutex_unlock(c->mu);
}

// refuse_if_empty: Main10 session create (or a session that emits nothing) is a skip, not a picture failure.
static int decode_all(CMSampleBufferRef *samples, int n, NSDictionary *spec, int w, int h, int ten,
                      pic **out, int *hw_flag, NSString **ident, int refuse_if_empty, char *why, size_t whyn)
{
    *hw_flag = -1; *ident = nil;
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(samples[0]);
    if (!fd) { snprintf(why, whyn, "sample has no format description"); return 1; }
    OSType fmt = ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    NSDictionary *attr = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
                            (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
                            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                            (id)kCVImageBufferColorPrimariesKey: (id)kCVImageBufferColorPrimaries_ITU_R_709_2,
                            (id)kCVImageBufferTransferFunctionKey: (id)kCVImageBufferTransferFunction_ITU_R_709_2,
                            (id)kCVImageBufferYCbCrMatrixKey: (id)kCVImageBufferYCbCrMatrix_ITU_R_709_2 };
    VTDecompressionSessionRef ds = NULL;
    OSStatus st = VTDecompressionSessionCreate(NULL, fd, (__bridge CFDictionaryRef)spec, (__bridge CFDictionaryRef)attr, NULL, &ds);
    if (st || !ds) {
        snprintf(why, whyn, "VTDecompressionSessionCreate -> %d", (int)(st ? st : -1));
        if (ds) CFRelease(ds);
        return refuse_if_empty ? 77 : 1;
    }
    pthread_mutex_t mu;
    pthread_mutex_init(&mu, NULL);
    // Heap box: the decode block captures the pointer, and the callback may run on another thread until Wait returns.
    dec_box *box = calloc(1, sizeof *box);
    if (!box) {
        VTDecompressionSessionInvalidate(ds); CFRelease(ds); pthread_mutex_destroy(&mu);
        snprintf(why, whyn, "out of memory"); return 1;
    }
    box->n = n; box->w = w; box->h = h; box->ten = ten; box->mu = &mu;
    for (int i = 0; i < n; i++) {
        CMSampleBufferRef sb = samples[i];
        if (!sb) { box->errors++; continue; }
        st = VTDecompressionSessionDecodeFrameWithOutputHandler(ds, sb, 0, NULL,
            ^(OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime dur) {
                (void)flags; (void)dur; dec_store(box, status, image, pts);
            });
        if (st) {
            pthread_mutex_lock(&mu);
            box->errors++;
            if (!box->why[0]) snprintf(box->why, sizeof box->why, "DecodeFrame %d -> %d", i, (int)st);
            pthread_mutex_unlock(&mu);
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(ds);
    *hw_flag = session_bool(ds, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder);
    *ident = decoder_ident(ds);
    VTDecompressionSessionInvalidate(ds);
    CFRelease(ds);
    pthread_mutex_destroy(&mu);
    for (int i = 0; i < n; i++) out[i] = box->frames[i];
    int got = box->got, errors = box->errors;
    if (got != n || errors) {
        snprintf(why, whyn, "%s%sdecoded %d of %d, errors %d", box->why, box->why[0] ? "; " : "", got, n, errors);
        free(box);
        if (refuse_if_empty && got == 0) return 77;
        return 1;
    }
    free(box);
    return 0;
}

static void release_case(pic **src, pic **hw, pic **sw, CMSampleBufferRef *samples)
{
    for (int i = 0; i < kFrames; i++) {
        pic_free(src[i]); pic_free(hw[i]); pic_free(sw[i]);
        if (samples[i]) CFRelease(samples[i]);
    }
    fflush(stdout);
}

static int run_case(NSString *encoderID, int w, int h, int ten, int allow_skip)
{
    const char *name = ten ? "Main10" : "8-bit";
    printf("%s %dx%d  %d frames%s\n", name, w, h, kFrames, h < 256 ? "  (height under 256 rows)" : "");
    pic *src[kFrames] = {0}, *hw[kFrames] = {0}, *sw[kFrames] = {0};
    CMSampleBufferRef samples[kFrames] = {0};
    pthread_mutex_t mu;
    pthread_mutex_init(&mu, NULL);
    enc_box enc; memset(&enc, 0, sizeof enc);
    enc.n = kFrames; enc.mu = &mu;
    OSType fmt = ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    NSMutableDictionary *spec = [@{ (id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @NO } mutableCopy];
    if (encoderID) spec[(id)kVTVideoEncoderSpecification_EncoderID] = encoderID;
    NSDictionary *srcAttr = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
                               (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
                               (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    VTCompressionSessionRef cs = NULL;
    NSString *pinned = encoderID;
    OSStatus st = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_HEVC, (__bridge CFDictionaryRef)spec,
                                            (__bridge CFDictionaryRef)srcAttr, NULL, enc_cb, &enc, &cs);
    if ((st || !cs) && pinned) {
        printf("  EncoderID %s create -> %d; retrying with hardware encode disabled\n", pinned.UTF8String, (int)st);
        if (cs) { CFRelease(cs); cs = NULL; }
        pinned = nil;
        [spec removeObjectForKey:(id)kVTVideoEncoderSpecification_EncoderID];
        st = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_HEVC, (__bridge CFDictionaryRef)spec,
                                        (__bridge CFDictionaryRef)srcAttr, NULL, enc_cb, &enc, &cs);
    }
    if (st || !cs) {
        printf("  %s VTCompressionSessionCreate -> %d\n", allow_skip ? "SKIP software encoder refused the stream," : "FAIL", (int)st);
        if (cs) CFRelease(cs);
        pthread_mutex_destroy(&mu);
        return allow_skip ? 77 : 1;
    }
    CFStringRef level = ten ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel;
    OSStatus pst = VTSessionSetProperty(cs, kVTCompressionPropertyKey_ProfileLevel, level);
    if (pst && allow_skip) {
        printf("  SKIP software encoder refused the profile, ProfileLevel -> %d\n", (int)pst);
        VTCompressionSessionInvalidate(cs); CFRelease(cs); pthread_mutex_destroy(&mu);
        return 77;
    }
    if (pst) printf("  ProfileLevel -> %d, continuing with the encoder default\n", (int)pst);
    if (VTSessionSetProperty(cs, kVTCompressionPropertyKey_Quality, (__bridge CFTypeRef)@1.0)) {
        double bps = (double)w * h * 30.0 * 2.0; if (bps < 8000000) bps = 8000000;
        VTSessionSetProperty(cs, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bps));
    }
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@30);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@30);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    if (VTCompressionSessionPrepareToEncodeFrames(cs)) {
        printf("  %s PrepareToEncodeFrames failed\n", allow_skip ? "SKIP" : "FAIL");
        VTCompressionSessionInvalidate(cs); CFRelease(cs); pthread_mutex_destroy(&mu);
        return allow_skip ? 77 : 1;
    }
    for (int i = 0; i < kFrames; i++) {
        @autoreleasepool {
            src[i] = pic_new(w, h, ten);
            if (!src[i]) { enc.errors++; break; }
            fill_pattern(src[i], i);
            CVPixelBufferRef pb = pb_from_pic(src[i]);
            if (!pb) { enc.errors++; break; }
            NSDictionary *kf = i == 0 ? @{ (id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES } : nil;
            st = VTCompressionSessionEncodeFrame(cs, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), (__bridge CFDictionaryRef)kf, (void *)(intptr_t)(i + 1), NULL);
            CFRelease(pb);
            if (st) { printf("  EncodeFrame %d -> %d\n", i, (int)st); enc.errors++; }
        }
    }
    VTCompressionSessionCompleteFrames(cs, kCMTimeInvalid);
    int enc_hw = session_bool(cs, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder);
    NSString *used = session_string(cs, kVTCompressionPropertyKey_EncoderID);
    VTCompressionSessionInvalidate(cs); CFRelease(cs);
    pthread_mutex_destroy(&mu);
    for (int i = 0; i < kFrames; i++) samples[i] = enc.samples[i];
    size_t bytes = 0; int ns = 0;
    CMSampleBufferRef first = NULL;
    for (int i = 0; i < kFrames; i++) if (samples[i]) { if (!first) first = samples[i]; bytes += CMSampleBufferGetTotalSampleSize(samples[i]); ns++; }
    int profile = first ? hevc_profile_idc(CMSampleBufferGetFormatDescription(first)) : -1;
    printf("  encoder %s UsingHardwareAcceleratedVideoEncoder=%s samples=%d %.2f Mbit/s profile_idc=%d\n",
           used.UTF8String ?: "(id unavailable)", yesno(enc_hw), ns, ns ? bytes * 8.0 * 30.0 / ns / 1e6 : 0, profile);
    if (allow_skip && ns == 0) {
        printf("  SKIP software encoder produced no Main10 stream (errors %d)\n", enc.errors);
        release_case(src, hw, sw, samples); return 77;
    }
    if (allow_skip && profile != 2) {
        printf("  SKIP software encoder did not emit HEVC Main10 (profile_idc %d)\n", profile);
        release_case(src, hw, sw, samples); return 77;
    }
    if (ns != kFrames || enc.errors || enc_hw == 1 || driver_encoder(used) || (pinned && used && ![used isEqualToString:pinned])) {
        printf("  FAIL software encode is not an independent bitstream (hardware reported on, or this driver's encoder) (errors %d, hardware=%s)\n", enc.errors, yesno(enc_hw));
        release_case(src, hw, sw, samples); return 1;
    }
    char why[180] = {0};
    int sw_hw = -1, hw_hw = -1;
    NSString *sw_id = nil, *hw_id = nil;
    NSDictionary *swSpec = @{ (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @NO };
    int src_dec = decode_all(samples, kFrames, swSpec, w, h, ten, sw, &sw_hw, &sw_id, 0, why, sizeof why);
    printf("  software decoder UsingHardwareAcceleratedVideoDecoder=%s %s\n", yesno(sw_hw), sw_id.UTF8String ?: "unavailable");
    if (src_dec) { printf("  FAIL software decode: %s\n", why); release_case(src, hw, sw, samples); return 1; }
    NSDictionary *hwSpec = @{ (id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES };
    int hw_dec = decode_all(samples, kFrames, hwSpec, w, h, ten, hw, &hw_hw, &hw_id, allow_skip, why, sizeof why);
    printf("  hardware decoder UsingHardwareAcceleratedVideoDecoder=%s %s\n", yesno(hw_hw), hw_id.UTF8String ?: "unavailable");
    if (ten && sw[0] && hw[0] && (sw[0]->shift != 6 || hw[0]->shift != 6))
        printf("  10-bit container shift sw=%d hw=%d (6 is MSB-aligned)\n", sw[0]->shift, hw[0]->shift);
    if (hw_dec == 77) { printf("  SKIP hardware decoder refused the stream: %s\n", why); release_case(src, hw, sw, samples); return 77; }
    if (hw_dec) { printf("  FAIL hardware decode: %s\n", why); release_case(src, hw, sw, samples); return 1; }
    if (hw_hw != 1 || sw_hw == 1) {
        printf("  FAIL decoder selection hardware=%s software=%s\n", yesno(hw_hw), yesno(sw_hw));
        release_case(src, hw, sw, samples); return 1;
    }

    int peak = ten ? 1023 : 255, thresh = ten ? 32 : 8, outside = 0, worst = 0;
    double sum[6] = {0}, minp[6];
    for (int k = 0; k < 6; k++) minp[k] = 99;
    int max_hs[2] = {0}, max_hwsw[2] = {0};
    int tile_frame = -1, tile_plane = -1, tile_x = 0, tile_y = 0, tile_d = 0;
    double worst_score = 99;
    for (int i = 0; i < kFrames; i++) {
        int csamp = (w / 2) * (h / 2) * 2;
        double hy = plane_psnr(hw[i]->y, src[i]->y, w * h, peak, &max_hs[0]);
        double hc = plane_psnr(hw[i]->c, src[i]->c, csamp, peak, &max_hs[1]);
        double sy = plane_psnr(sw[i]->y, src[i]->y, w * h, peak, NULL);
        double sc = plane_psnr(sw[i]->c, src[i]->c, csamp, peak, NULL);
        double dy = plane_psnr(hw[i]->y, sw[i]->y, w * h, peak, &max_hwsw[0]);
        double dc = plane_psnr(hw[i]->c, sw[i]->c, csamp, peak, &max_hwsw[1]);
        double v[6] = { hy, hc, sy, sc, dy, dc };
        for (int k = 0; k < 6; k++) { sum[k] += v[k]; if (v[k] < minp[k]) minp[k] = v[k]; }
        int bad = hy < 38 || hc < 38 || dy < 38 || dc < 38 || fabs(hy - sy) > 1.5 || fabs(hc - sc) > 1.5;
        if (bad) outside++;
        if (hy < worst_score) { worst_score = hy; worst = i; }
        if (tile_frame < 0) {
            for (int ty = 0; ty < h && tile_frame < 0; ty += kTileH) for (int tx = 0; tx < w && tile_frame < 0; tx += kTileW) {
                int lw = tx + kTileW > w ? w - tx : kTileW, lh = ty + kTileH > h ? h - ty : kTileH;
                if (lw < 1 || lh < 2) continue;
                int md = rect_max(hw[i]->y, sw[i]->y, w, tx, ty, lw, lh);
                if (md >= thresh) { tile_frame = i; tile_plane = 0; tile_x = tx; tile_y = ty; tile_d = md; break; }
                int cmd = rect_max(hw[i]->c, sw[i]->c, w, tx, ty / 2, lw, lh / 2);
                if (cmd >= thresh) { tile_frame = i; tile_plane = 1; tile_x = tx; tile_y = ty; tile_d = cmd; }
            }
        }
    }
    const char *plane_name[2] = { "Y", "UV" };
    for (int p = 0; p < 2; p++)
        printf("  plane %s  hw/src %.2f (min %.2f)  sw/src %.2f (min %.2f)  hw/sw %.2f (min %.2f) dB  max|hw-src| %d  max|hw-sw| %d\n",
               plane_name[p], sum[p] / kFrames, minp[p], sum[2 + p] / kFrames, minp[2 + p], sum[4 + p] / kFrames, minp[4 + p],
               max_hs[p], max_hwsw[p]);
    if (tile_frame < 0) printf("  first mismatching tile: none (hw vs sw, 128x32 grid, max|d| >= %d)\n", thresh);
    else printf("  first mismatching tile: frame %d %s (%d,%d) max|hw-sw|=%d (128x32 luma grid, threshold %d)\n",
                tile_frame, tile_plane ? "UV" : "Y", tile_x, tile_y, tile_d, thresh);

    pic *badp_h = hw[worst], *badp_s = src[worst];
    double c128 = residual_corr(badp_h->y, badp_s->y, w, h, kTileW, 0);
    double c32 = residual_corr(badp_h->y, badp_s->y, w, h, 0, kTileH);
    int tiles = 0, bad_tiles = 0;
    double floor = ten ? 48.0 : 12.0;
    for (int ty = 0; ty < h; ty += kTileH) for (int tx = 0; tx < w; tx += kTileW) {
        int lw = tx + kTileW > w ? w - tx : kTileW, lh = ty + kTileH > h ? h - ty : kTileH;
        tiles++;
        if (rect_mean(badp_h->y, badp_s->y, w, tx, ty, lw, lh) > floor) bad_tiles++;
    }
    double frac = tiles ? (double)bad_tiles / tiles : 0;
    // Heuristic: a scrambled Blackwell layout repeats every 128 columns and 32 rows, so the residual correlates there.
    if (worst_score < 38 && frac >= 0.5 && (fabs(c128) >= 0.35 || fabs(c32) >= 0.35))
        printf("  hint: error is concentrated in 128x32-tile-periodic patterns (frame %d residual corr 128 cols %.2f, 32 rows %.2f, %.0f%% of tiles); a Blackwell-layout mistake scrambles tiles of that size\n",
               worst, c128, c32, frac * 100.0);
    if (outside) {
        printf("  FAIL %d frame(s) outside the gate; worst frame %d hw/src Y %.2f dB\n", outside, worst, worst_score);
        printf("  gate: every frame Y and UV, hw/src and hw/sw, >= 38 dB, and |hw/src - sw/src| <= 1.5 dB\n");
        release_case(src, hw, sw, samples); return 1;
    }
    printf("  PASS\n");
    release_case(src, hw, sw, samples);
    return 0;
}

int main(void)
{
    @autoreleasepool {
        setenv("NVMTL_NO_NVENC_HEVC", "1", 1);
        printf("NVMTL_NO_NVENC_HEVC=1\n");
        if (getenv("NVMTL_NO_NVDEC_HEVC"))
            printf("NVMTL_NO_NVDEC_HEVC is set; hardware HEVC decode will not register\n");
        NSString *encoder = pick_software_encoder();
        static const int sizes[][2] = { { 1920, 1080 }, { 1280, 144 } };
        int failed = 0, skipped = 0;
        for (int i = 0; i < 2; i++) {
            int rc = run_case(encoder, sizes[i][0], sizes[i][1], 0, 0);
            if (rc) failed = 1;
        }
        for (int i = 0; i < 2; i++) {
            int rc = run_case(encoder, sizes[i][0], sizes[i][1], 1, 1);
            if (rc == 77) skipped = 1;
            else if (rc) failed = 1;
        }
        if (failed) { printf("result: FAIL 1\n"); return 1; }
        if (skipped) { printf("result: SKIP 77\n"); return 77; }
        printf("result: PASS 0\n");
        return 0;
    }
}
