// dscale: show one 1024 px squircle as three 112x112 layers, so the compositor does the shrink.
//   A  layer contents = the 1024 image, default minification filter
//   B  the same, minificationFilter = trilinear
//   C  pre-scaled to 112 px on the CPU at high interpolation quality
// usage: dscale [seconds]     default 20. Look at the window; there is no numeric result.
// build: clang -fobjc-arc -O2 -Wall -o dscale dscale.m -framework Cocoa -framework QuartzCore -framework CoreGraphics
// exit: 0 the window stayed up for the requested time
// output: the screen position of the three layers (bottom-left origin), so a later
//   dshot can be cropped onto them. A and B looking like C means the compositor
//   minified smoothly. A and B looking jagged, with C smooth, means the shrink
//   happened and aliased.
// permission: none. Launch the .app with open -a.
// cannot show: a mean error. cilanczos and minify print numbers for their own
//   paths; this one is whatever WindowServer does with a layer's contents.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
static CGImageRef make_img(int S, uint8_t *buf)
{
    for (int y = 0; y < S; y++) for (int x = 0; x < S; x++) {
        double a = fabs((x + 0.5) / S * 2 - 1) / 0.8, b = fabs((y + 0.5) / S * 2 - 1) / 0.8, f = pow(a, 5) + pow(b, 5), d = (pow(f, 0.2) - 1.0) * 0.8 * S * 0.5;
        double al = fmin(fmax(0.5 - d, 0.0), 1.0); uint8_t *q = buf + ((size_t)y * S + x) * 4; uint8_t v = (uint8_t)(255 * al + 0.5);
        q[0] = q[1] = q[2] = v; q[3] = v; }   // premultiplied white with alpha
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(buf, S, S, 8, S * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    return CGBitmapContextCreateImage(c);
}
int main(int argc, char **argv) { @autoreleasepool {
    int secs = argc > 1 ? atoi(argv[1]) : 20; const int S = 1024, D = 112;
    NSApplication *app = [NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 300, 480, 160) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.level = NSFloatingWindowLevel; w.backgroundColor = NSColor.blackColor; NSView *v = w.contentView; v.wantsLayer = YES; v.layer.backgroundColor = NSColor.blackColor.CGColor;
    uint8_t *big = malloc((size_t)S * S * 4); CGImageRef img = make_img(S, big);
    // C: CPU pre-scale with high quality interpolation
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); uint8_t *small = calloc((size_t)D * D, 4);
    CGContextRef sc = CGBitmapContextCreate(small, D, D, 8, D * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little); CGContextSetInterpolationQuality(sc, kCGInterpolationHigh);
    CGContextDrawImage(sc, CGRectMake(0, 0, D, D), img); CGImageRef pre = CGBitmapContextCreateImage(sc);
    for (int i = 0; i < 3; i++) {
        CALayer *l = [CALayer layer]; l.frame = CGRectMake(24 + i * 152, 24, D, D); l.contents = (__bridge id)(i == 2 ? pre : img); l.contentsGravity = kCAGravityResize; l.contentsScale = 1.0;
        if (i == 1) { l.minificationFilter = kCAFilterTrilinear; } [v.layer addSublayer:l]; }
    [w makeKeyAndOrderFront:nil]; printf("window up; layers A(default) B(trilinear) C(pre-scaled) at x=124,276,428 y=324..436 (screen coords, bottom-left origin)\n"); fflush(stdout);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
} return 0; }
