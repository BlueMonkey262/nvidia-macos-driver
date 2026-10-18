// cpuicon: draw an app's icon on the CPU (NSImage into a bitmap) at 112, 128, and 64 px and save PNGs.
// usage: cpuicon /Applications/Some.app out_prefix
// build: clang -fobjc-arc -O2 -Wall -o cpuicon cpuicon.m -framework Cocoa
// exit: 0 the three PNGs were written; 2 arguments missing
// output: the icon representations' pixel sizes, then "wrote <prefix>_<size>.png".
//   Interpolation is NSImageInterpolationHigh. This is the CPU path.
// permission: none
// cannot show: the Dock. The Dock minifies on the GPU, through WindowServer.
//   A smooth PNG here and a jagged Dock icon means the aliasing is in that GPU path.
#import <Cocoa/Cocoa.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("usage: cpuicon /Applications/Some.app out_prefix\n"); return 2; }
    [NSApplication sharedApplication];
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:@(argv[1])]; printf("reps: "); for (NSImageRep *r in icon.representations) printf("%zdx%zd ", (ssize_t)r.pixelsWide, (ssize_t)r.pixelsHigh); printf("\n");
    int sizes[] = { 112, 128, 64 };
    for (int k = 0; k < 3; k++) { int D = sizes[k];
        NSBitmapImageRep *bm = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:D pixelsHigh:D bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
        NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithBitmapImageRep:bm]; [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:g];
        g.imageInterpolation = NSImageInterpolationHigh; [icon drawInRect:NSMakeRect(0, 0, D, D) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0]; [NSGraphicsContext restoreGraphicsState];
        NSString *p = [NSString stringWithFormat:@"%s_%d.png", argv[2], D]; [[bm representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:p atomically:YES]; printf("wrote %s\n", p.UTF8String); }
    return 0; } }
