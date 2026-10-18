// dnoise: a full-screen Metal window of moving hashed noise, so an encoder has a busy picture.
// usage: dnoise [seconds [noise_amplitude_0_255]]     default 120 seconds, amplitude 40
// build: clang -fobjc-arc -O2 -Wall -o dnoise dnoise.m -framework Cocoa -framework Metal -framework QuartzCore -framework CoreVideo
// exit: 0 the window ran for the requested time
// output: one line, the window size in points and the noise amplitude. Nothing else.
//   The right-hand part of the frame (x > 640) uses the full amplitude; the left uses 0.3 of it.
// permission: none. Launch the .app with open -a. It uses the screensaver window level
//   and covers the display, so capture and the physical monitor both see the noise.
// cannot show: a bitrate. Pair it with streamrate, or with Sunshine pointed at this screen.
//   It is not a game: motion is per-pixel hash noise, which an encoder treats as harsh detail.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
static id<MTLCommandQueue> g_q; static CAMetalLayer *g_layer; static CVDisplayLinkRef g_dl; static volatile int g_n; static id<MTLRenderPipelineState> g_ps; static float g_amp = 40;
static NSString *msl = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 pos [[position]]; };\n"
"vertex VO vq(uint vid [[vertex_id]]) { float2 q[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; VO o; o.pos = float4(q[vid], 0, 1); return o; }\n"
"struct U { float t; float amp; };\n"
"fragment float4 fs(VO i [[stage_in]], constant U &u [[buffer(0)]]) { float2 p = i.pos.xy; uint x = uint(p.x) + uint(u.t * 7.0), y = uint(p.y); uint h = x * 2654435761u ^ (y * 40503u + uint(u.t)); h ^= h >> 13; h *= 1274126177u; h ^= h >> 16;\n"
"  float n = (float(h & 255u) / 255.0 - 0.5) * u.amp / 255.0 * (p.x > 640.0 ? 1.0 : 0.3); float g = 0.35 + 0.25 * sin((p.x + u.t * 9.0) * 0.01) * cos(p.y * 0.012 + u.t * 0.05);\n"
"  return float4(g + n, g * 0.8 + n, 0.5 - g * 0.3 + n, 1.0); }\n";
static void frame(void) { @autoreleasepool { id<CAMetalDrawable> d = [g_layer nextDrawable]; if (!d) return; int n = g_n++;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp]; [e setRenderPipelineState:g_ps]; float u[2] = { (float)n, g_amp }; [e setFragmentBytes:u length:8 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding]; [cb presentDrawable:d]; [cb commit]; } }
static CVReturn dl(CVDisplayLinkRef l, const CVTimeStamp *n, const CVTimeStamp *o, CVOptionFlags f, CVOptionFlags *fo, void *c) { dispatch_async(dispatch_get_main_queue(), ^{ frame(); }); return kCVReturnSuccess; }
int main(int argc, char **argv) { @autoreleasepool {
    int secs = argc > 1 ? atoi(argv[1]) : 120; if (argc > 2) g_amp = atof(argv[2]); NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSRect sr = NSScreen.mainScreen.frame; NSWindow *w = [[NSWindow alloc] initWithContentRect:sr styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO]; w.level = NSScreenSaverWindowLevel; NSView *v = w.contentView; v.wantsLayer = YES;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); g_q = [dev newCommandQueue]; NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vq"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; g_ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    g_layer = [CAMetalLayer layer]; g_layer.device = dev; g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm; g_layer.frame = v.bounds; g_layer.drawableSize = sr.size; [v.layer addSublayer:g_layer]; [w makeKeyAndOrderFront:nil];
    printf("busy full-screen window %.0fx%.0f, noise amplitude %.0f\n", sr.size.width, sr.size.height, g_amp); fflush(stdout);
    CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &g_dl); CVDisplayLinkSetOutputCallback(g_dl, dl, NULL); CVDisplayLinkStart(g_dl);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]]; } return 0; }
