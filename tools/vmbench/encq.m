// encq: encode a screenshot with the hardware H.264 encoder and with Apple's software encoder,
// decode with the software decoder, and report bytes/frame and PSNR-Y (whole frame and the bottom 100 rows).
// Saves the last decoded frame of each run as a PNG.
// usage: encq shot.png outprefix [frames [order]]
//   frames defaults to 30. order is a string of h, s, H, S (default hsHS):
//   h/s static hardware/software, H/S the same picture scrolled 3 px per frame.
//   ENCQ_GAP, if set, is seconds to sleep between runs.
// build: clang -fobjc-arc -O2 -Wall -o encq encq.m -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics
// exit: 0 the runs finished (a create failure is printed and that run is skipped);
//   2 arguments missing
// output: per run, IDR size, average bytes/frame, Mbit/s at 60 fps, decoded count,
//   mean and minimum whole-frame PSNR-Y, and PSNR-Y of the bottom 100 rows.
//   PSNR near 50 dB on a still desktop is far above a visible loss. The bitrate
//   here is what the encoder emitted for AverageBitRate 25 Mbit/s, which the
//   unpatched library does not follow (it sits at a constant QP).
// permission: none. Needs the hardware encoder for the h/H runs (a Turing session
//   on this driver). No other process may be holding that engine.
// cannot show: a live stream, motion search quality on a game, or rate control.
//   qualprobe is the Quality-property test; streamrate is the wire. One hardware
//   session per process is the card; this tool releases each session so the next
//   letter in order can open. The earlier build did not, and "hH" failed -12908.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>
typedef struct { NSMutableArray *s; int err; } ctx_t;
static void cb(void *r, void *src, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) { ctx_t *c = r; @synchronized (c->s) { if (st || !sb) c->err++; else [c->s addObject:(__bridge id)sb]; } }
static CVPixelBufferRef bgra_from_png(const char *path, int *w, int *h)
{
    CGImageSourceRef is = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)], NULL); CGImageRef im = CGImageSourceCreateImageAtIndex(is, 0, NULL); *w = (int)CGImageGetWidth(im); *h = (int)CGImageGetHeight(im);
    CVPixelBufferRef pb = NULL; CVPixelBufferCreate(NULL, *w, *h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &pb);
    CVPixelBufferLockBaseAddress(pb, 0); CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), *w, *h, 8, CVPixelBufferGetBytesPerRow(pb), cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(c, CGRectMake(0, 0, *w, *h), im); CGContextRelease(c); CVPixelBufferUnlockBaseAddress(pb, 0); return pb;
}
static VTPixelTransferSessionRef g_xfer;
static CVPixelBufferRef to_nv12(CVPixelBufferRef bgra, int shift)
{
    int w = (int)CVPixelBufferGetWidth(bgra), h = (int)CVPixelBufferGetHeight(bgra); CVPixelBufferRef shifted = bgra;
    if (w > 0) shift %= w;
    if (shift) {   // rotate each row left by `shift` pixels
        CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &shifted);
        CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(shifted, 0);
        for (int y = 0; y < h; y++) { uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddress(bgra) + (size_t)y * CVPixelBufferGetBytesPerRow(bgra), *d = (uint8_t *)CVPixelBufferGetBaseAddress(shifted) + (size_t)y * CVPixelBufferGetBytesPerRow(shifted);
            memcpy(d, s + shift * 4, (size_t)(w - shift) * 4); memcpy(d + (size_t)(w - shift) * 4, s, (size_t)shift * 4); }
        CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(shifted, 0); }
    CVPixelBufferRef nv = NULL; CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &nv);
    VTPixelTransferSessionTransferImage(g_xfer, shifted, nv); if (shifted != bgra) CFRelease(shifted); return nv;
}
static double psnr_y(CVPixelBufferRef a, CVPixelBufferRef b, int y0, int y1)
{
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    uint8_t *pa = CVPixelBufferGetBaseAddressOfPlane(a, 0), *pb = CVPixelBufferGetBaseAddressOfPlane(b, 0); size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0); int w = (int)CVPixelBufferGetWidth(a);
    double se = 0; size_t n = 0; for (int y = y0; y < y1; y++) for (int x = 0; x < w; x++) { double d = (double)pa[y * sa + x] - pb[y * sb + x]; se += d * d; n++; }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly); return se == 0 ? 99 : 10 * log10(255.0 * 255.0 / (se / n)); }
static void save_png(CVPixelBufferRef nv, const char *path)
{
    int w = (int)CVPixelBufferGetWidth(nv), h = (int)CVPixelBufferGetHeight(nv); CVPixelBufferRef bg = NULL; CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &bg);
    VTPixelTransferSessionTransferImage(g_xfer, nv, bg); CVPixelBufferLockBaseAddress(bg, kCVPixelBufferLock_ReadOnly); CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(bg), w, h, 8, CVPixelBufferGetBytesPerRow(bg), cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little); CGImageRef im = CGBitmapContextCreateImage(c);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL); CGImageDestinationAddImage(d, im, NULL); CGImageDestinationFinalize(d); CFRelease(d); CGImageRelease(im); CGContextRelease(c); CVPixelBufferUnlockBaseAddress(bg, kCVPixelBufferLock_ReadOnly); CFRelease(bg); }
static void run(const char *name, BOOL hw, CVPixelBufferRef big, int N, int scroll, const char *outprefix)
{
    int w = (int)CVPixelBufferGetWidth(big), h = (int)CVPixelBufferGetHeight(big);
    NSMutableArray *src = [NSMutableArray array]; for (int i = 0; i < N; i++) [src addObject:(__bridge_transfer id)to_nv12(big, scroll * i)];
    ctx_t c = { [NSMutableArray array], 0 };
    NSDictionary *spec = hw ? @{ (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES } : @{ (id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @NO };
    VTCompressionSessionRef cs = NULL; OSStatus st = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_H264, (__bridge CFDictionaryRef)spec, NULL, NULL, cb, &c, &cs);
    if (!cs) { printf("%-9s create failed %d\n", name, (int)st); return; }
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue); VTSessionSetProperty(cs, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@1000000); VTSessionSetProperty(cs, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@25000000);
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@60); VTCompressionSessionPrepareToEncodeFrames(cs);
    for (int i = 0; i < N; i++) VTCompressionSessionEncodeFrame(cs, (__bridge CVPixelBufferRef)src[i], CMTimeMake(i, 60), CMTimeMake(1, 60), NULL, NULL, NULL);
    VTCompressionSessionCompleteFrames(cs, kCMTimeInvalid); VTCompressionSessionInvalidate(cs);
    if ((int)c.s.count != N) { printf("%-9s got %lu of %d frames, errors %d\n", name, (unsigned long)c.s.count, N, c.err); CFRelease(cs); return; }
    size_t total = 0, first = 0; for (int i = 0; i < N; i++) { size_t z = CMSampleBufferGetTotalSampleSize((__bridge CMSampleBufferRef)c.s[i]); total += z; if (!i) first = z; }
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)c.s[0]);
    VTDecompressionSessionRef ds = NULL; VTDecompressionSessionCreate(NULL, fd, (__bridge CFDictionaryRef)@{ (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @NO }, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }, NULL, &ds);
    __block double sumA = 0, sumD = 0, minA = 99; __block int got = 0; __block CVPixelBufferRef last = NULL;
    for (id s in c.s) VTDecompressionSessionDecodeFrameWithOutputHandler(ds, (__bridge CMSampleBufferRef)s, 0, NULL, ^(OSStatus e, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
        if (e || !img) return; int i = (int)pts.value; if (i < 0 || i >= N) return; CVPixelBufferRef ref = (__bridge CVPixelBufferRef)src[i];
        double pa = psnr_y(ref, img, 0, h), pd = psnr_y(ref, img, h - 100, h); sumA += pa; sumD += pd; if (pa < minA) minA = pa; got++; if (i == N - 1) { if (last) CFRelease(last); last = (CVPixelBufferRef)CFRetain(img); } });
    VTDecompressionSessionWaitForAsynchronousFrames(ds); VTDecompressionSessionInvalidate(ds); if (ds) CFRelease(ds);
    printf("%-9s %-8s  IDR %7zu B  avg %7.0f B/frame (%5.1f Mbit/s at 60 fps)  decoded %d  PSNR-Y whole %.1f dB (min %.1f)  dock strip %.1f dB\n", name, scroll ? "scroll" : "static", first, (double)total / N, (double)total / N * 8 * 60 / 1e6, got, sumA / (got ? got : 1), minA, sumD / (got ? got : 1));
    if (last) { char p[512]; snprintf(p, sizeof p, "%s_%s_%s.png", outprefix, name, scroll ? "scroll" : "static"); save_png(last, p); }
    CFRelease(cs); // Create's +1. Invalidate alone left the engine busy, so the next run failed -12908.
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("usage: encq shot.png outprefix [frames [order]]\n"); return 2; }
    int N = argc > 3 ? atoi(argv[3]) : 30; int w, h; CVPixelBufferRef big = bgra_from_png(argv[1], &w, &h); printf("source %dx%d, %d frames\n", w, h, N);
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); (void)d; usleep(300000); VTPixelTransferSessionCreate(NULL, &g_xfer);
    const char *order = argc > 4 ? argv[4] : "hsHS"; int gap = getenv("ENCQ_GAP") ? atoi(getenv("ENCQ_GAP")) : 0;   // h/s static, H/S scrolling
    for (const char *o = order; *o; o++) { if (o != order && gap) { printf("(waiting %d s)\n", gap); sleep(gap); } switch (*o) { case 'h': run("hardware", YES, big, N, 0, argv[2]); break; case 's': run("software", NO, big, N, 0, argv[2]); break; case 'H': run("hardware", YES, big, N, 3, argv[2]); break; case 'S': run("software", NO, big, N, 3, argv[2]); break; } }
    return 0; } }
