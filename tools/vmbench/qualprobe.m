// qualprobe: does VTSessionSetProperty(Quality) change the hardware encoder's output size, including mid-stream?
// Encodes a scrolling screenshot (3 px/frame) in seven phases of 20 frames. Quality is set
// before each phase, after the first phase that is a change on a live session.
// usage: qualprobe shot.png
// build: clang -fobjc-arc -O2 -Wall -o qualprobe qualprobe.m -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal -framework ImageIO -framework CoreGraphics
// exit: 0 the phases were printed; 2 arguments missing, or the hardware session did not open
// output: per phase, the Quality value, the SetProperty status, the QP the library
//   should store (trunc(51 - 41*q + 0.5)), and mean bytes/frame over the phase
//   with the first frames skipped (3 in phase 0, 1 afterwards) so the IDR and
//   the in-flight frame do not dominate. Mbit/s is that average at 60 fps.
//   A mid-stream change that the library honours moves the byte count with the QP.
//   Quality 0.5, 0.9, 0.25, 0.7, 0.5, 1.0, 0.1 are the phases, in that order.
// permission: none. Needs the hardware encoder and a free engine.
// cannot show: PSNR, or that the plugin's rate controller is in the path. This
//   writes Quality directly. AverageBitRate is not set. Release plugin builds
//   ignore NVMTL_* in the environment; that knob is unrelated to this probe.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
typedef struct { NSMutableArray *sizes; } ctx_t;
static void cb(void *r, void *src, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) { ctx_t *c = r; if (!st && sb) @synchronized (c->sizes) { [c->sizes addObject:@(CMSampleBufferGetTotalSampleSize(sb))]; } }
static VTPixelTransferSessionRef xfer;
static CVPixelBufferRef frame_nv12(CVPixelBufferRef bgra, int shift) {
    int w = (int)CVPixelBufferGetWidth(bgra), h = (int)CVPixelBufferGetHeight(bgra); if (w > 0) shift %= w;
    CVPixelBufferRef sh = NULL; CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &sh);
    CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(sh, 0);
    for (int y = 0; y < h; y++) { uint8_t *s = (uint8_t *)CVPixelBufferGetBaseAddress(bgra) + (size_t)y * CVPixelBufferGetBytesPerRow(bgra), *d = (uint8_t *)CVPixelBufferGetBaseAddress(sh) + (size_t)y * CVPixelBufferGetBytesPerRow(sh); memcpy(d, s + shift * 4, (size_t)(w - shift) * 4); memcpy(d + (size_t)(w - shift) * 4, s, (size_t)shift * 4); }
    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(sh, 0);
    CVPixelBufferRef nv = NULL; CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &nv); VTPixelTransferSessionTransferImage(xfer, sh, nv); CFRelease(sh); return nv; }
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { printf("usage: qualprobe shot.png\n"); return 2; }
    CGImageSourceRef is = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])], NULL); CGImageRef im = CGImageSourceCreateImageAtIndex(is, 0, NULL); int w = (int)CGImageGetWidth(im), h = (int)CGImageGetHeight(im);
    CVPixelBufferRef big = NULL; CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} }, &big); CVPixelBufferLockBaseAddress(big, 0);
    CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(big), w, h, 8, CVPixelBufferGetBytesPerRow(big), CGColorSpaceCreateWithName(kCGColorSpaceSRGB), kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little); CGContextDrawImage(c, CGRectMake(0, 0, w, h), im); CVPixelBufferUnlockBaseAddress(big, 0);
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); (void)d; usleep(300000); VTPixelTransferSessionCreate(NULL, &xfer);
    ctx_t cx = { [NSMutableArray array] }; VTCompressionSessionRef cs = NULL;
    OSStatus st = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_H264, (__bridge CFDictionaryRef)@{ (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES }, NULL, NULL, cb, &cx, &cs); if (!cs) { printf("create failed %d\n", (int)st); return 2; }
    VTSessionSetProperty(cs, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue); VTSessionSetProperty(cs, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse); VTSessionSetProperty(cs, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@1000000);
    // phases: 20 frames each; Quality values set BEFORE the first frame of the phase (mid-stream changes after the first phase)
    double q[] = { 0.5, 0.9, 0.25, 0.7, 0.5, 1.0, 0.1 }; int phases = 7, per = 20, n = 0;
    for (int p = 0; p < phases; p++) {
        OSStatus s = VTSessionSetProperty(cs, kVTCompressionPropertyKey_Quality, (__bridge CFTypeRef)@(q[p]));
        for (int i = 0; i < per; i++, n++) { CVPixelBufferRef nv = frame_nv12(big, 3 * (n % 200)); VTCompressionSessionEncodeFrame(cs, nv, CMTimeMake(n, 60), CMTimeMake(1, 60), NULL, NULL, NULL); CFRelease(nv); }
        VTCompressionSessionCompleteFrames(cs, kCMTimeInvalid);
        double expect_qp = (int)(q[p] * -41 + 51 + 0.5); long sum = 0; int cnt = 0, k0 = p * per + (p ? 1 : 3); @synchronized (cx.sizes) { for (int i = k0; i < (p + 1) * per && i < (int)cx.sizes.count; i++) { sum += [cx.sizes[i] longValue]; cnt++; } }
        printf("phase %d: Quality %.2f (SetProperty -> %d, library QP should be %.0f): avg %7.0f bytes/frame over %d frames  (%.1f Mbit/s at 60 fps)\n", p, q[p], (int)s, expect_qp, cnt ? (double)sum / cnt : 0, cnt, cnt ? (double)sum / cnt * 8 * 60 / 1e6 : 0);
    }
    VTCompressionSessionInvalidate(cs); CFRelease(cs); return 0; } }
