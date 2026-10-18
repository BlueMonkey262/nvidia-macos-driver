// dbar: a Metal window with a full-height white bar that jumps a fixed number of pixels every presented frame.
// A torn composite shows the bar at two x positions in different rows of one captured frame. usage: dbar [seconds [pixels_per_frame [slow]]]
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
static id<MTLCommandQueue> g_q; static CAMetalLayer *g_layer; static CVDisplayLinkRef g_dl; static volatile int g_n; static int g_step = 37; static id<MTLRenderPipelineState> g_ps;
static NSString *msl = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 pos [[position]]; };\n"
"vertex VO vq(uint vid [[vertex_id]], constant float2 &r [[buffer(0)]]) { float2 q[6] = {float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1)}; float x0 = r.x, x1 = r.y; float2 p = q[vid]; float x = mix(x0, x1, p.x) * 2 - 1; float y = p.y * 2 - 1; VO o; o.pos = float4(x, y, 0, 1); return o; }\n"
"fragment float4 fs(VO i [[stage_in]]) { return float4(1, 1, 1, 1); }\n";
static void frame(void) { @autoreleasepool {
    id<CAMetalDrawable> d = [g_layer nextDrawable]; if (!d) return; int n = g_n++; const int W = 1200; int x = (n * g_step) % (W - 40);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:g_ps]; float r[2] = { x / (float)W, (x + 40) / (float)W }; [e setVertexBytes:r length:8 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6]; [e endEncoding];
    [cb presentDrawable:d]; [cb commit]; } }
static CVReturn dl(CVDisplayLinkRef l, const CVTimeStamp *n, const CVTimeStamp *o, CVOptionFlags f, CVOptionFlags *fo, void *c) { dispatch_async(dispatch_get_main_queue(), ^{ frame(); }); return kCVReturnSuccess; }
int main(int argc, char **argv) { @autoreleasepool {
    int secs = argc > 1 ? atoi(argv[1]) : 60; g_step = argc > 2 ? atoi(argv[2]) : 37; NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 1200, 800) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO]; w.level = NSFloatingWindowLevel; NSView *v = w.contentView; v.wantsLayer = YES;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); g_q = [dev newCommandQueue]; NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vq"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; g_ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    g_layer = [CAMetalLayer layer]; g_layer.device = dev; g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm; g_layer.frame = v.bounds; g_layer.drawableSize = CGSizeMake(1200, 800); [v.layer addSublayer:g_layer]; [w makeKeyAndOrderFront:nil];
    printf("bar window at screen x 100..1300, y(bottom-left) 100..900; step %d px/frame\n", g_step); fflush(stdout);
    CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &g_dl); CVDisplayLinkSetOutputCallback(g_dl, dl, NULL); CVDisplayLinkStart(g_dl);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]]; } return 0; }
