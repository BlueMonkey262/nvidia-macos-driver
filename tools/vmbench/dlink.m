// dlink: how often CVDisplayLink fires, and how even the callbacks are.
// usage: dlink [seconds]     default 5
// build: clang -fobjc-arc -O2 -Wall -o dlink dlink.m -framework Foundation -framework CoreVideo -framework CoreGraphics
// exit: 0 stats printed; 1 fewer than 2 callbacks
// output: the display mode's nominal refresh (this can be 0 when the mode does not
//   publish one; the "nominal period" line from CVDisplayLink is the one to trust),
//   then callbacks per second and the interval in ms (mean, median, population
//   stdev, p5, p95, max). A healthy vblank is stdev well under a millisecond.
// permission: none. No window. It still needs a display and a WindowServer.
// cannot show: when frames were presented. The link is the timer, not the scanout.
//   dpres is the present path. A tight link and a loose dgl is an OpenGL result.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
static double g_t[200000]; static int g_n;
static CVReturn cb(CVDisplayLinkRef l, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags f, CVOptionFlags *fo, void *c)
{ if (g_n < 200000) g_t[g_n++] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; return kCVReturnSuccess; }
int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
int main(int argc, char **argv) { @autoreleasepool {
    int secs = argc > 1 ? atoi(argv[1]) : 5;
    CGDirectDisplayID d = CGMainDisplayID(); CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
    printf("main display %u mode %zux%zu refresh %.2f Hz\n", d, CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m), CGDisplayModeGetRefreshRate(m));
    CVDisplayLinkRef l; CVDisplayLinkCreateWithCGDisplay(d, &l); CVDisplayLinkSetOutputCallback(l, cb, NULL);
    CVTime nom = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(l);
    printf("nominal period %.3f ms (%.1f Hz)\n", 1000.0 * nom.timeValue / nom.timeScale, (double)nom.timeScale / nom.timeValue);
    CVDisplayLinkStart(l); [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]]; CVDisplayLinkStop(l);
    int n = g_n - 1; if (n < 2) { printf("only %d callbacks\n", g_n); return 1; }
    double iv[n], sum = 0, mx = 0; for (int i = 0; i < n; i++) { iv[i] = g_t[i + 1] - g_t[i]; sum += iv[i]; if (iv[i] > mx) mx = iv[i]; }
    double mean = sum / n, var = 0; for (int i = 0; i < n; i++) var += (iv[i] - mean) * (iv[i] - mean);
    qsort(iv, n, sizeof(double), cmp);
    printf("callbacks %d in %ds => %.1f/s; interval ms mean %.2f median %.2f stdev %.2f p5 %.2f p95 %.2f max %.1f\n", g_n, secs, g_n / (double)secs, mean, iv[n / 2], sqrt(var / n), iv[n / 20], iv[n - n / 20 - 1], mx);
} return 0; }
