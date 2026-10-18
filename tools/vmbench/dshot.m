// dshot: save a full-resolution PNG of the main display via ScreenCaptureKit.
// usage: dshot out.png [more.png ...]     one PNG per argument, 1 second apart
// build: clang -fobjc-arc -O2 -Wall -o dshot dshot.m -framework Cocoa -framework ScreenCaptureKit -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics
// exit: 0 every file was written; 1 a capture or a write failed; 2 no path was given
// output: "saved WxH -> path" per file. The cursor is off. Pixel format is BGRA.
// permission: Screen Recording. Use the .app from build_all.sh, via open -a.
// cannot show: motion between the shots beyond the 1 second gap, or a pixel error.
//   It is how you grab the frame that encq and a crop of dscale want to keep.
#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { printf("usage: dshot out.png [more.png ...]\n"); return 2; }
    [NSApplication sharedApplication];
    for (int a = 1; a < argc; a++) {
        __block int rc = 1; dispatch_semaphore_t sem = dispatch_semaphore_create(0); NSString *path = @(argv[a]);
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
            if (e || !c.displays.count) { printf("no content: %s\n", e ? e.localizedDescription.UTF8String : "no displays"); dispatch_semaphore_signal(sem); return; }
            SCDisplay *d = c.displays[0]; SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
            SCStreamConfiguration *cfg = [SCStreamConfiguration new]; cfg.width = d.width; cfg.height = d.height; cfg.showsCursor = NO; cfg.pixelFormat = kCVPixelFormatType_32BGRA;
            [SCScreenshotManager captureImageWithFilter:f configuration:cfg completionHandler:^(CGImageRef img, NSError *e2) {
                if (!img) { printf("capture failed: %s\n", e2.localizedDescription.UTF8String); dispatch_semaphore_signal(sem); return; }
                CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
                CGImageDestinationAddImage(dst, img, NULL); BOOL ok = CGImageDestinationFinalize(dst); CFRelease(dst);
                printf("%s %zux%zu -> %s\n", ok ? "saved" : "write failed", CGImageGetWidth(img), CGImageGetHeight(img), path.UTF8String); rc = ok ? 0 : 1; dispatch_semaphore_signal(sem);
            }];
        }];
        while (dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW)) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (rc) return rc; if (a + 1 < argc) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    }
} return 0; }
