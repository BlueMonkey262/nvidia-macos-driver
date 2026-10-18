// tearscan: a window with a full-height white bar that jumps a fixed step every presented frame, drawn with OpenGL or
// Metal, while ScreenCaptureKit captures the main display. A captured frame whose bar is at two x positions in
// different rows is a tear inside the composited content (not a scan-out tear: the panel itself is not captured).
// usage: tearscan gl|metal [seconds [step [swapinterval [cap|nocap [window|full]]]]]
//   defaults: 15 s, 37 px per frame, swap interval 1, capture on, a 1200x800 window at (100, 100)
//   full: a borderless window over the whole main display (the window at (0, 0) in its coordinates)
//   nocap: draw only, no capture (then analyse screenshots from dshot with tearpng)
// output: one line: app frames, captured frames, blank frames (no bar found) and TORN frames with how many cuts they had.
//   A few torn frames at the very start or end of a run are start-up artefacts; compare gl against metal in one session.
// needs: Screen Recording for the bundle (see capture-host in README.md). build: see build_all.sh (it builds this program
//   once as a program and once as probe.dylib, which capture-host loads).
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/gl.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/runtime.h>
#include <math.h>
static int WX = 100, WY = 100, WW = 1200, WH = 800;   // FULL=1 in argv[6]: a borderless window over the whole main display
static int g_step = 37, g_frames, g_torn, g_seen, g_blank; static NSLock *g_lock; static int g_hist[8];
@interface Rec : NSObject <SCStreamOutput> @end
@implementation Rec
- (void)stream:(SCStream *)s didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)t
{
    if (t != SCStreamOutputTypeScreen) return;
    CFArrayRef a = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (a && CFArrayGetCount(a)) { NSNumber *st = ((__bridge NSDictionary *)CFArrayGetValueAtIndex(a, 0))[SCStreamFrameInfoStatus]; if (st && st.integerValue != SCFrameStatusComplete) return; }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb); if (!pb) return;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = CVPixelBufferGetBaseAddress(pb); size_t bpr = CVPixelBufferGetBytesPerRow(pb), H = CVPixelBufferGetHeight(pb);
    int xs[16], nx = 0, minx = 1 << 30, maxx = -1;
    for (int k = 0; k < 16; k++) {
        size_t y = H - WY - WH + 10 + (size_t)k * (WH - 20) / 15;   // capture rows are top-down; window y is bottom-up
        const uint8_t *row = base + y * bpr; int x = -1;
        for (int i = WX + 2; i < WX + WW - 2; i++) if (row[i * 4 + 1] > 200 && row[i * 4 + 2] > 200 && row[i * 4] > 200) { x = i; break; }
        xs[k] = x; if (x >= 0) { nx++; if (x < minx) minx = x; if (x > maxx) maxx = x; }
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    [g_lock lock]; g_seen++;
    if (nx == 0) g_blank++;
    else if (nx < 16 || maxx - minx > 3) { g_torn++; int cuts = 0; for (int k = 1; k < 16; k++) if (abs(xs[k] - xs[k - 1]) > 3) cuts++; g_hist[cuts > 7 ? 7 : cuts]++; }
    [g_lock unlock];
}
@end
static id<MTLCommandQueue> g_q; static CAMetalLayer *g_layer; static id<MTLRenderPipelineState> g_ps; static NSOpenGLContext *g_ctx;
static NSString *msl = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 pos [[position]]; };\n"
"vertex VO vq(uint vid [[vertex_id]], constant float2 &r [[buffer(0)]]) { float2 q[6] = {float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1)}; float2 p = q[vid]; float x = mix(r.x, r.y, p.x); VO o; o.pos = float4(x * 2 - 1, p.y * 2 - 1, 0, 1); return o; }\n"
"fragment float4 fs(VO i [[stage_in]]) { return float4(1, 1, 1, 1); }\n";
static void frame_metal(void) { @autoreleasepool {
    id<CAMetalDrawable> d = [g_layer nextDrawable]; if (!d) return; int n = g_frames++; int x = (n * g_step) % (WW - 40);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:g_ps];
    float r[2] = { x / (float)WW, (x + 40) / (float)WW }; [e setVertexBytes:r length:8 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [e endEncoding];
    [cb presentDrawable:d]; [cb commit]; } }
static CVReturn dl(CVDisplayLinkRef l, const CVTimeStamp *n, const CVTimeStamp *o, CVOptionFlags f, CVOptionFlags *fo, void *c) { dispatch_async(dispatch_get_main_queue(), ^{ frame_metal(); }); return kCVReturnSuccess; }
static void frame_gl(void) { @autoreleasepool {
    int n = g_frames++; int x = (n * g_step) % (WW - 40); float x0 = -1 + 2 * x / (float)WW, x1 = -1 + 2 * (x + 40) / (float)WW;
    glViewport(0, 0, WW, WH); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); glColor4f(1, 1, 1, 1);
    glBegin(GL_QUADS); glVertex2f(x0, -1); glVertex2f(x1, -1); glVertex2f(x1, 1); glVertex2f(x0, 1); glEnd(); [g_ctx flushBuffer]; } }
int main(int argc, char **argv) { @autoreleasepool {
    BOOL gl = argc > 1 && !strcmp(argv[1], "gl"); int secs = argc > 2 ? atoi(argv[2]) : 15; g_step = argc > 3 ? atoi(argv[3]) : 37; int swap = argc > 4 ? atoi(argv[4]) : 1; BOOL nocap = argc > 5 && !strcmp(argv[5], "nocap"); if (argc > 6 && !strcmp(argv[6], "full")) { NSRect sf = NSScreen.mainScreen.frame; WX = 0; WY = 0; WW = (int)sf.size.width; WH = (int)sf.size.height; } g_lock = [NSLock new];
    NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(WX, WY, WW, WH) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO]; w.level = (WW > 1500) ? NSScreenSaverWindowLevel : NSFloatingWindowLevel;
    CVDisplayLinkRef dlr = NULL; NSView *cv = w.contentView;
    if (gl) {
        NSOpenGLPixelFormatAttribute at[] = { NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated, NSOpenGLPFAColorSize, 24, 0 };
        NSOpenGLView *v = [[NSOpenGLView alloc] initWithFrame:NSMakeRect(0, 0, WW, WH) pixelFormat:[[NSOpenGLPixelFormat alloc] initWithAttributes:at]]; w.contentView = v; [w makeKeyAndOrderFront:nil];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        g_ctx = v.openGLContext; [g_ctx setView:v]; [g_ctx makeCurrentContext]; GLint si = swap; [g_ctx setValues:&si forParameter:NSOpenGLContextParameterSwapInterval];
    } else {
        cv.wantsLayer = YES; id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); g_q = [dev newCommandQueue]; NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vq"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; g_ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        g_layer = [CAMetalLayer layer]; g_layer.device = dev; g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm; g_layer.frame = cv.bounds; g_layer.drawableSize = CGSizeMake(WW, WH); [cv.layer addSublayer:g_layer]; [w makeKeyAndOrderFront:nil];
        CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &dlr); CVDisplayLinkSetOutputCallback(dlr, dl, NULL); CVDisplayLinkStart(dlr);
    }
    __block SCStream *stream = nil; __block NSString *err = nil; dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    if (nocap) dispatch_semaphore_signal(sem); else
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
        if (e || !c.displays.count) { err = e ? e.localizedDescription : @"no displays"; dispatch_semaphore_signal(sem); return; }
        SCDisplay *d = c.displays[0]; SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
        SCStreamConfiguration *cfg = [SCStreamConfiguration new]; cfg.width = d.width; cfg.height = d.height; cfg.minimumFrameInterval = CMTimeMake(1, 60); cfg.pixelFormat = kCVPixelFormatType_32BGRA; cfg.showsCursor = NO; cfg.queueDepth = 5;
        stream = [[SCStream alloc] initWithFilter:f configuration:cfg delegate:nil]; Rec *r = [Rec new]; objc_setAssociatedObject(stream, "r", r, OBJC_ASSOCIATION_RETAIN);
        NSError *ae = nil; [stream addStreamOutput:r type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_queue_create("sck", DISPATCH_QUEUE_SERIAL) error:&ae];
        [stream startCaptureWithCompletionHandler:^(NSError *se) { if (se) err = se.localizedDescription; dispatch_semaphore_signal(sem); }]; }];
    while (dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW)) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (err) { printf("SCK error: %s\n", err.UTF8String); return 2; }
    double t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
    while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9 - t0 < secs) {
        if (gl) { frame_gl(); [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0]]; }
        else [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    if (stream) [stream stopCaptureWithCompletionHandler:^(NSError *e) {}]; [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    [g_lock lock]; printf("%s: app frames %d (%.1f/s), captured %d, blank %d, TORN %d (%.1f%%); torn frames by number of bar cuts 1..7+: %d %d %d %d %d %d %d\n", gl ? "OpenGL" : "Metal", g_frames, g_frames / (double)secs, g_seen, g_blank, g_torn,
           g_seen ? 100.0 * g_torn / g_seen : 0.0, g_hist[1], g_hist[2], g_hist[3], g_hist[4], g_hist[5], g_hist[6], g_hist[7]); [g_lock unlock];
} return 0; }
