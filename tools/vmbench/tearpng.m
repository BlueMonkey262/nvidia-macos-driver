// tearpng: bar-tear analysis of PNG screenshots (see tearscan). usage: tearpng file.png ...
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
enum { WX = 100, WY = 100, WW = 1200, WH = 800 };
int main(int argc, char **argv) { @autoreleasepool { int torn = 0, ok = 0, blank = 0;
  for (int a = 1; a < argc; a++) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[a])], NULL); if (!src) continue;
    CGImageRef im = CGImageSourceCreateImageAtIndex(src, 0, NULL); size_t W = CGImageGetWidth(im), H = CGImageGetHeight(im);
    uint8_t *buf = calloc(W * H, 4); CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast); CGContextDrawImage(c, CGRectMake(0, 0, W, H), im);
    int xs[16], nx = 0, mn = 1 << 30, mx = -1;
    for (int k = 0; k < 16; k++) { size_t y = H - WY - WH + 10 + (size_t)k * (WH - 20) / 15; uint8_t *row = buf + y * W * 4; int x = -1;
      for (int i = WX + 2; i < WX + WW - 2; i++) if (row[i * 4] > 200 && row[i * 4 + 1] > 200 && row[i * 4 + 2] > 200) { x = i; break; }
      xs[k] = x; if (x >= 0) { nx++; if (x < mn) mn = x; if (x > mx) mx = x; } }
    printf("%s: %s", argv[a], nx == 0 ? "no bar" : (nx < 16 || mx - mn > 3) ? "TORN" : "ok");
    if (nx) { printf(" x:"); for (int k = 0; k < 16; k++) printf(" %d", xs[k]); } printf("\n");
    if (!nx) blank++; else if (nx < 16 || mx - mn > 3) torn++; else ok++;
    free(buf); CGContextRelease(c); CGColorSpaceRelease(cs); CGImageRelease(im); CFRelease(src); }
  printf("SUMMARY ok %d torn %d no-bar %d\n", ok, torn, blank); } return 0; }
