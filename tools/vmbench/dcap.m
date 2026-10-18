// dcap: how often and how evenly AVFoundation screen capture delivers frames while the screen animates.
// usage: dcap [fps [seconds [pixfmt]]]     pixfmt is bgra (default) or nv12. fps default 120, seconds 6.
//   Draws a moving white box and captures the main display.
// build: clang -fobjc-arc -O2 -Wall -o dcap dcap.m -framework Cocoa -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework QuartzCore
// exit: 0 stats printed; 1 fewer than 5 frames (often Screen Recording was refused);
//   2 the session could not take the input or the output
// output: achieved fps and the callback-to-callback interval in ms (mean, median,
//   population stdev, p5, p95, max). Requested fps is the minFrameDuration cap.
//   A result stuck near 87 fps when 120 was requested is the AVFoundation ceiling
//   seen on this guest, not a present-rate problem. Compare with dsck.
// permission: Screen Recording (TCC). A binary started over ssh has none; wrap
//   with build_all.sh and grant it to the .app, then launch with open -a.
// cannot show: latency from present to callback (that is dlat), or whether the
//   pixels are the right frame. Late frames are discarded, so a stall looks like
//   a hole in the intervals, and the discarded frame is gone.
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#include <math.h>
static double g_t[100000]; static int g_n; static NSLock *g_lock;
@interface Rec : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> @end
@implementation Rec
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c
{ double t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; [g_lock lock]; if (g_n < 100000) g_t[g_n++] = t; [g_lock unlock]; }
@end
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
int main(int argc, char **argv) { @autoreleasepool {
    int fps = argc > 1 ? atoi(argv[1]) : 120, secs = argc > 2 ? atoi(argv[2]) : 6;
    bool nv12 = argc > 3 && !strcmp(argv[3], "nv12");
    g_lock = [NSLock new];
    NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 900, 500) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.level = NSFloatingWindowLevel; w.backgroundColor = NSColor.blackColor; [w makeKeyAndOrderFront:nil];
    NSView *v = w.contentView; v.wantsLayer = YES;
    CALayer *box = [CALayer layer]; box.backgroundColor = NSColor.whiteColor.CGColor; box.frame = CGRectMake(0, 200, 120, 120); [v.layer addSublayer:box];
    CABasicAnimation *an = [CABasicAnimation animationWithKeyPath:@"position.x"]; an.fromValue = @60; an.toValue = @840; an.duration = 0.7; an.autoreverses = YES; an.repeatCount = HUGE_VALF; [box addAnimation:an forKey:@"m"];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    AVCaptureSession *s = [AVCaptureSession new];
    AVCaptureScreenInput *in = [[AVCaptureScreenInput alloc] initWithDisplayID:CGMainDisplayID()];
    in.minFrameDuration = CMTimeMake(1, fps); in.capturesCursor = NO; in.capturesMouseClicks = NO;
    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA) };
    out.alwaysDiscardsLateVideoFrames = YES;
    Rec *r = [Rec new]; dispatch_queue_t q = dispatch_queue_create("cap", DISPATCH_QUEUE_SERIAL); [out setSampleBufferDelegate:r queue:q];
    if (![s canAddInput:in] || ![s canAddOutput:out]) { printf("cannot add input/output\n"); return 2; }
    [s addInput:in]; [s addOutput:out]; [s startRunning];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    [s stopRunning];
    (void)r; // AVCapture does not retain the delegate; ARC frees a local at its last use
    [g_lock lock]; int n = g_n - 1; if (n < 5) { printf("only %d frames (screen recording permission?)\n", g_n); return 1; }
    double iv[n], sum = 0, mx = 0; for (int i = 0; i < n; i++) { iv[i] = g_t[i + 1] - g_t[i]; sum += iv[i]; if (iv[i] > mx) mx = iv[i]; }
    double mean = sum / n, var = 0; for (int i = 0; i < n; i++) var += (iv[i] - mean) * (iv[i] - mean);
    qsort(iv, n, sizeof(double), cmp);
    printf("requested %d fps, %s: %d frames in %ds => %.1f fps; interval ms mean %.2f median %.2f stdev %.2f p5 %.2f p95 %.2f max %.1f\n", fps, nv12 ? "NV12" : "BGRA", g_n, secs, g_n / (double)secs, mean, iv[n / 2], sqrt(var / n), iv[n / 20], iv[n - n / 20 - 1], mx);
} return 0; }
