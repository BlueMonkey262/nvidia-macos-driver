// dlat: latency from "this frame was presented" to "AVFoundation delivered a frame showing it".
// A Metal window flips between a red and a blue clear every ~250 ms (30 vblanks at 120 Hz).
// usage: dlat [fps [seconds]]     default 120 fps, 10 seconds
// build: clang -fobjc-arc -O2 -Wall -o dlat dlat.m -framework Cocoa -framework AVFoundation -framework Metal -framework QuartzCore -framework CoreVideo -framework CoreMedia
// exit: 0 stats printed; 1 fewer than 3 matched colour changes; 2 the session could not be built
// output: one latency per colour change, present time to the callback that first
//   shows that colour, in ms (mean, median, p5, p95, max). The first two changes
//   and the last are dropped so startup and teardown do not count. Median is the
//   number to compare across runs. 17-26 ms is the AVFoundation range measured
//   on this guest; a few milliseconds is ScreenCaptureKit (dlat2).
// permission: Screen Recording. Use the .app from build_all.sh, granted in
//   System Settings, launched with open -a. An ssh binary matches nothing.
// cannot show: glass-to-glass delay, encode time, or a miss that is the wrong
//   colour because of colour management. One pixel at the window centre is the
//   whole test. The point is scaled from display points into the buffer, which
//   is a no-op when the buffer is 1x; a planar buffer with no base address is skipped.
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#define MAXE 400
static double g_pres[MAXE], g_cap[MAXE]; static volatile int g_nchg;      // per change index
static NSLock *g_lock; static id<MTLCommandQueue> g_q; static CAMetalLayer *g_layer; static CVDisplayLinkRef g_dl;
static volatile int g_tick; static volatile int g_color = -1;              // 0 red, 1 blue
static int g_x, g_y, g_dw, g_dh;
static int cmpd(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
static void frame(void)
{
    @autoreleasepool {
        id<CAMetalDrawable> d = [g_layer nextDrawable]; if (!d) return;
        int t = g_tick++; int color = (t / 30) & 1; BOOL change = (t % 30 == 0);
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = color ? MTLClearColorMake(0, 0, 1, 1) : MTLClearColorMake(1, 0, 0, 1);
        id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e endEncoding];
        if (change) {
            [g_lock lock]; int k = g_nchg < MAXE ? g_nchg++ : -1; [g_lock unlock];
            if (k >= 0) [d addPresentedHandler:^(id<MTLDrawable> dr) { g_pres[k] = dr.presentedTime * 1000.0; }];
            g_color = color;                                                      // the colour the capture should now start showing
        }
        [cb presentDrawable:d]; [cb commit];
    }
}
static CVReturn dl(CVDisplayLinkRef l, const CVTimeStamp *n, const CVTimeStamp *o, CVOptionFlags f, CVOptionFlags *fo, void *c) { dispatch_async(dispatch_get_main_queue(), ^{ frame(); }); return kCVReturnSuccess; }
@interface Rec : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> @end
@implementation Rec
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c
{
    double now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb); if (!pb || g_dw <= 0 || g_dh <= 0) return;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t bw = CVPixelBufferGetWidth(pb), bh = CVPixelBufferGetHeight(pb);
    size_t x = bw ? (size_t)g_x * bw / (size_t)g_dw : 0, y = bh ? (size_t)g_y * bh / (size_t)g_dh : 0;
    int seen = -1;
    if (base && x < bw && y < bh) {
        uint8_t *p = base + y * CVPixelBufferGetBytesPerRow(pb) + x * 4;
        int B = p[0], R = p[2];
        seen = (R > 200 && B < 80) ? 0 : ((B > 200 && R < 80) ? 1 : -1);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    [g_lock lock];
    int k = g_nchg - 1;                                                          // the latest change that was submitted
    if (k >= 0 && seen == g_color && g_cap[k] == 0) g_cap[k] = now;
    [g_lock unlock];
}
@end
int main(int argc, char **argv) { @autoreleasepool {
    int fps = argc > 1 ? atoi(argv[1]) : 120, secs = argc > 2 ? atoi(argv[2]) : 10; g_lock = [NSLock new];
    NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSRect r = NSMakeRect(100, 100, 900, 500);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.level = NSFloatingWindowLevel; NSView *v = w.contentView; v.wantsLayer = YES;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); g_q = [dev newCommandQueue];
    g_layer = [CAMetalLayer layer]; g_layer.device = dev; g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm; g_layer.frame = v.bounds; g_layer.drawableSize = CGSizeMake(900, 500);
    [v.layer addSublayer:g_layer]; [w makeKeyAndOrderFront:nil];
    CGRect db = CGDisplayBounds(CGMainDisplayID()); g_dw = (int)db.size.width; g_dh = (int)db.size.height;
    g_x = (int)(r.origin.x + r.size.width / 2); g_y = (int)(db.size.height - (r.origin.y + r.size.height / 2));
    CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &g_dl); CVDisplayLinkSetOutputCallback(g_dl, dl, NULL); CVDisplayLinkStart(g_dl);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    AVCaptureSession *s = [AVCaptureSession new]; AVCaptureScreenInput *in = [[AVCaptureScreenInput alloc] initWithDisplayID:CGMainDisplayID()];
    in.minFrameDuration = CMTimeMake(1, fps); in.capturesCursor = NO;
    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new]; out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) }; out.alwaysDiscardsLateVideoFrames = YES;
    Rec *rec = [Rec new]; [out setSampleBufferDelegate:rec queue:dispatch_queue_create("cap", DISPATCH_QUEUE_SERIAL)];
    if (![s canAddInput:in] || ![s canAddOutput:out]) { printf("cannot add input/output\n"); return 2; }
    [s addInput:in]; [s addOutput:out]; [s startRunning];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    [s stopRunning]; CVDisplayLinkStop(g_dl);
    (void)rec; // AVCapture does not retain the delegate; ARC frees a local at its last use
    double lat[MAXE]; int n = 0;
    [g_lock lock];
    for (int k = 2; k < g_nchg - 1; k++) if (g_pres[k] > 0 && g_cap[k] > 0) lat[n++] = g_cap[k] - g_pres[k];
    printf("changes %d, matched %d\n", g_nchg, n);
    if (n < 3) { printf("too few matches (screen recording permission?)\n"); return 1; }
    double sum = 0; for (int i = 0; i < n; i++) sum += lat[i];
    qsort(lat, n, sizeof(double), cmpd);
    printf("capture latency (presented on screen -> capture callback), requested %d fps: n %d mean %.1f ms  median %.1f  p5 %.1f  p95 %.1f  max %.1f\n", fps, n, sum / n, lat[n / 2], lat[n / 20], lat[n - n / 20 - 1], lat[n - 1]);
} return 0; }
