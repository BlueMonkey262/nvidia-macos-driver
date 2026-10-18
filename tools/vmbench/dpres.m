// dpres: present a Metal frame every vblank and record when each drawable was presented.
// usage: dpres [seconds]     default 6
// build: clang -fobjc-arc -O2 -Wall -o dpres dpres.m -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo
// exit: 0 stats printed; 1 fewer than 5 presented times
// output: "submitted" is nextDrawable frames handed to the command buffer.
//   "presented-handler fired" is how many of those reported a presentedTime.
//   The interval line is the gap between those times, in ms (mean, median,
//   population stdev, p5, p95, max). On a steady panel the median should sit
//   on the refresh period (16.7 ms at 60 Hz, 8.3 ms at 120 Hz) and stdev should
//   be well under a millisecond.
// permission: none. Launch the .app with open -a so the window is in the GUI session.
// cannot show: capture latency, tearing, or which process else is presenting.
//   A handler that never fires means the drawable was not presented, which this
//   print cannot explain. The clear colour is only so the window is obvious.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
static double g_p[100000]; static int g_np; static int g_submit; static NSLock *g_lock;
static id<MTLCommandQueue> g_q; static CAMetalLayer *g_layer; static CVDisplayLinkRef g_dl; static volatile int g_phase;
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
static void frame(void)
{
    @autoreleasepool {
        id<CAMetalDrawable> d = [g_layer nextDrawable]; if (!d) return;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        double v = 0.5 + 0.5 * sin(g_phase++ * 0.15); rp.colorAttachments[0].clearColor = MTLClearColorMake(v, 0.2, 1 - v, 1);
        id<MTLCommandBuffer> cb = [g_q commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e endEncoding];
        [d addPresentedHandler:^(id<MTLDrawable> dr) { double t = dr.presentedTime * 1000.0; if (t > 0) { [g_lock lock]; if (g_np < 100000) g_p[g_np++] = t; [g_lock unlock]; } }];
        [cb presentDrawable:d]; [cb commit]; g_submit++;
    }
}
static CVReturn dl(CVDisplayLinkRef l, const CVTimeStamp *n, const CVTimeStamp *o, CVOptionFlags f, CVOptionFlags *fo, void *c) { dispatch_async(dispatch_get_main_queue(), ^{ frame(); }); return kCVReturnSuccess; }
int main(int argc, char **argv) { @autoreleasepool {
    int secs = argc > 1 ? atoi(argv[1]) : 6; g_lock = [NSLock new];
    NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 900, 500) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.level = NSFloatingWindowLevel; NSView *v = w.contentView; v.wantsLayer = YES;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); g_q = [dev newCommandQueue];
    g_layer = [CAMetalLayer layer]; g_layer.device = dev; g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm; g_layer.frame = v.bounds; g_layer.drawableSize = CGSizeMake(900, 500);
    [v.layer addSublayer:g_layer]; [w makeKeyAndOrderFront:nil];
    printf("device %s\n", dev.name.UTF8String);
    CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &g_dl); CVDisplayLinkSetOutputCallback(g_dl, dl, NULL); CVDisplayLinkStart(g_dl);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]]; CVDisplayLinkStop(g_dl);
    [g_lock lock]; int n = g_np - 1; printf("submitted %d frames, presented-handler fired %d times\n", g_submit, g_np);
    if (n < 5) { [g_lock unlock]; return 1; }
    double iv[n], sum = 0, mx = 0; for (int i = 0; i < n; i++) { iv[i] = g_p[i + 1] - g_p[i]; sum += iv[i]; if (iv[i] > mx) mx = iv[i]; }
    double mean = sum / n, var = 0; for (int i = 0; i < n; i++) var += (iv[i] - mean) * (iv[i] - mean);
    qsort(iv, n, sizeof(double), cmp);
    printf("presented %.1f/s; interval ms mean %.2f median %.2f stdev %.2f p5 %.2f p95 %.2f max %.1f\n", g_np / (double)secs, mean, iv[n / 2], sqrt(var / n), iv[n / 20], iv[n - n / 20 - 1], mx);
    [g_lock unlock];
} return 0; }
