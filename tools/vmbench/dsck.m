// dsck: same delivery-rate test as dcap, using ScreenCaptureKit instead of AVFoundation.
// usage: dsck [fps [seconds]]     default 120 fps, 6 seconds. Draws the same moving box.
// build: clang -fobjc-arc -O2 -Wall -o dsck dsck.m -framework Cocoa -framework ScreenCaptureKit -framework QuartzCore -framework CoreMedia -framework CoreVideo
// exit: 0 stats printed; 1 fewer than 5 frames; 2 shareable content or startCapture failed
// output: achieved fps and callback interval in ms (mean, median, population stdev,
//   p5, p95, max). Frames whose SCStream status is not complete are ignored.
//   minimumFrameInterval is 1/fps and queueDepth is 5. On this guest an animation
//   at a 120 fps request came back near 60 fps, while the latency test (dlat2)
//   still saw callbacks 1-2 ms after the present. Rate and latency are different questions.
// permission: Screen Recording. Use the .app from build_all.sh, via open -a.
// cannot show: present-to-callback latency (dlat2), or why a frame was marked idle.
//   The first display SCShareableContent returns is the one captured.
#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <math.h>
static double g_t[100000]; static int g_n; static NSLock *g_lock;
@interface Rec : NSObject <SCStreamOutput> @end
@implementation Rec
- (void)stream:(SCStream *)s didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)t
{
    if (t != SCStreamOutputTypeScreen) return;
    CFArrayRef a = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (a && CFArrayGetCount(a)) { NSNumber *st = ((__bridge NSDictionary *)CFArrayGetValueAtIndex(a, 0))[SCStreamFrameInfoStatus]; if (st && st.integerValue != SCFrameStatusComplete) return; }
    double now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; [g_lock lock]; if (g_n < 100000) g_t[g_n++] = now; [g_lock unlock];
}
@end
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
int main(int argc, char **argv) { @autoreleasepool {
    int fps = argc > 1 ? atoi(argv[1]) : 120, secs = argc > 2 ? atoi(argv[2]) : 6; g_lock = [NSLock new];
    NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 900, 500) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.level = NSFloatingWindowLevel; w.backgroundColor = NSColor.blackColor; [w makeKeyAndOrderFront:nil];
    NSView *v = w.contentView; v.wantsLayer = YES; CALayer *box = [CALayer layer]; box.backgroundColor = NSColor.whiteColor.CGColor; box.frame = CGRectMake(0, 200, 120, 120); [v.layer addSublayer:box];
    CABasicAnimation *an = [CABasicAnimation animationWithKeyPath:@"position.x"]; an.fromValue = @60; an.toValue = @840; an.duration = 0.7; an.autoreverses = YES; an.repeatCount = HUGE_VALF; [box addAnimation:an forKey:@"m"];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    __block SCStream *stream = nil; __block NSString *err = nil; dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
        if (e || !c.displays.count) { err = e ? e.localizedDescription : @"no displays"; dispatch_semaphore_signal(sem); return; }
        SCDisplay *d = c.displays[0];
        SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
        SCStreamConfiguration *cfg = [SCStreamConfiguration new]; cfg.width = d.width; cfg.height = d.height;
        cfg.minimumFrameInterval = CMTimeMake(1, fps); cfg.pixelFormat = kCVPixelFormatType_32BGRA; cfg.showsCursor = NO; cfg.queueDepth = 5;
        stream = [[SCStream alloc] initWithFilter:f configuration:cfg delegate:nil];
        Rec *r = [Rec new]; objc_setAssociatedObject(stream, "r", r, OBJC_ASSOCIATION_RETAIN);
        NSError *ae = nil; [stream addStreamOutput:r type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_queue_create("sck", DISPATCH_QUEUE_SERIAL) error:&ae];
        [stream startCaptureWithCompletionHandler:^(NSError *se) { if (se) err = se.localizedDescription; dispatch_semaphore_signal(sem); }];
    }];
    while (dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW)) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (err) { printf("SCK error: %s\n", err.UTF8String); return 2; }
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    [stream stopCaptureWithCompletionHandler:^(NSError *e) {}];
    [g_lock lock]; int n = g_n - 1; if (n < 5) { printf("only %d frames\n", g_n); return 1; }
    double iv[n], sum = 0, mx = 0; for (int i = 0; i < n; i++) { iv[i] = g_t[i + 1] - g_t[i]; sum += iv[i]; if (iv[i] > mx) mx = iv[i]; }
    double mean = sum / n, var = 0; for (int i = 0; i < n; i++) var += (iv[i] - mean) * (iv[i] - mean);
    qsort(iv, n, sizeof(double), cmp);
    printf("ScreenCaptureKit requested %d fps: %d frames in %ds => %.1f fps; interval ms mean %.2f median %.2f stdev %.2f p5 %.2f p95 %.2f max %.1f\n", fps, g_n, secs, g_n / (double)secs, mean, iv[n / 2], sqrt(var / n), iv[n / 20], iv[n - n / 20 - 1], mx);
} return 0; }
