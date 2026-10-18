// dgl: steady OpenGL workload; prints how evenly flushBuffer returns, and draws a moving bar.
// usage: dgl [seconds [layers [swapinterval]]]
//   layers = full-window translucent quads per frame (GPU load). swapinterval defaults to 1.
// build: clang -fobjc-arc -O2 -Wall -o dgl dgl.m -framework Cocoa -framework OpenGL
// exit: 0 stats printed; 1 fewer than 2 frames
// output: fps and the flush-to-flush interval in ms (mean, median, population stdev,
//   p5, p95, max), then how many intervals fall on 0, 1, 2, 3, 4, or 5+ times 16.7 ms.
//   A 60 Hz panel that is actually pacing should be almost all "1x" and fps near 60.
//   The full-height white bar steps across the window (about 7 px per frame at 960 wide).
//   On the physical monitor a horizontal seam in that bar is a tear.
// permission: none. Launch the .app with open -a so the window is in the GUI session.
// cannot show: a game's own frame time, or a tear that was already in the framebuffer
//   before flush. The numbers are when flushBuffer returned, not when the panel scanned
//   the frame out. Swap interval 0 is uncapped and will peg the GPU.

#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#include <math.h>
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
int main(int argc, char **argv) { @autoreleasepool {
    int secs = argc > 1 ? atoi(argv[1]) : 10, layers = argc > 2 ? atoi(argv[2]) : 0, swap = argc > 3 ? atoi(argv[3]) : 1;
    NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 960, 540) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO]; w.level = NSFloatingWindowLevel;
    NSOpenGLPixelFormatAttribute at[] = { NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, 0 };
    NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:at]; NSOpenGLView *v = [[NSOpenGLView alloc] initWithFrame:NSMakeRect(0, 0, 960, 540) pixelFormat:pf]; [w setContentView:v]; [w makeKeyAndOrderFront:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    NSOpenGLContext *ctx = v.openGLContext; [ctx setView:v]; [ctx makeCurrentContext]; [ctx update]; GLint si = swap; [ctx setValues:&si forParameter:NSOpenGLContextParameterSwapInterval];
    printf("GL_RENDERER: %s | layers %d | swap interval %d | context view attached: %d window visible: %d occluded: %d\n", glGetString(GL_RENDERER), layers, swap, ctx.view != nil, w.isVisible, !(w.occlusionState & NSWindowOcclusionStateVisible));
    glEnable(GL_BLEND); glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    double *t = malloc(sizeof(double) * 100000); int n = 0; double t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6, now = t0; int frame = 0;
    while (now - t0 < secs * 1000.0 && n < 99999) {
        @autoreleasepool {
            glViewport(0, 0, 960, 540); glClearColor(0.1f, 0.1f, 0.2f, 1); glClear(GL_COLOR_BUFFER_BIT);
            glBegin(GL_QUADS); for (int i = 0; i < layers; i++) { float s = 0.2f + 0.8f * (float)((i + frame) % 7) / 7.0f; glColor4f(0.2f + 0.1f * (i % 5), 0.5f, 0.8f - 0.1f * (i % 4), 0.08f); glVertex2f(-s, -s); glVertex2f(s, -s); glVertex2f(s, s); glVertex2f(-s, s); } glEnd();
            glColor4f(1, 1, 1, 1); float x = -0.9f + 1.8f * (float)(frame % 120) / 120.0f; glBegin(GL_QUADS); glVertex2f(x, -1); glVertex2f(x + 0.03f, -1); glVertex2f(x + 0.03f, 1); glVertex2f(x, 1); glEnd();
            [ctx flushBuffer]; frame++; if (frame % 30 == 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0]]; }
        now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; t[n++] = now; }
    if (n < 2) { printf("only %d frames\n", n); return 1; }
    int m = n - 1; double iv[m], sum = 0, mx = 0; for (int i = 0; i < m; i++) { iv[i] = t[i + 1] - t[i]; sum += iv[i]; if (iv[i] > mx) mx = iv[i]; }
    double mean = sum / m, var = 0; for (int i = 0; i < m; i++) var += (iv[i] - mean) * (iv[i] - mean); double s[m]; memcpy(s, iv, sizeof s); qsort(s, m, sizeof(double), cmp);
    int g[6] = {0}; for (int i = 0; i < m; i++) { int b = (int)(iv[i] / 16.7 + 0.5); g[b > 5 ? 5 : b]++; }
    printf("frames %d => %.1f fps; interval ms mean %.1f median %.1f stdev %.1f p5 %.1f p95 %.1f max %.0f\n", n, n / (double)secs, mean, s[m / 2], sqrt(var / m), s[m / 20], s[m - m / 20 - 1], mx);
    printf("intervals by refresh multiple (16.7 ms): <=0.5:%d  1x:%d  2x:%d  3x:%d  4x:%d  5x+:%d\n", g[0], g[1], g[2], g[3], g[4], g[5]);
} return 0; }
