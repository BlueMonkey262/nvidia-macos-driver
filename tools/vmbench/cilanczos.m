// cilanczos: shrink a smooth 1024 px squircle with CILanczosScaleTransform.
// The GPU (Metal) context and Core Image's software renderer are both compared
// with a CPU area-average of the source alpha. Sizes: 128, 112 (Dock-like), 100, 64.
// usage: cilanczos
// build: clang -fobjc-arc -O2 -Wall -o cilanczos cilanczos.m -framework Foundation -framework CoreImage -framework Metal -framework CoreGraphics
// exit: 0 PASS (every GPU result under 3.0 mean abs error); 1 FAIL
// output: per size, GPU and software mean abs error and in-between alpha counts.
//   Only the GPU number is gated. The software number is the reference renderer
//   on the same filter, so a GPU that matches it and misses the box filter is a
//   different failure from a GPU that matches neither.
// permission: none
// cannot show: which shader WindowServer actually ran. This is CILanczosScaleTransform
//   in this process. A Dock icon can still be jagged if WindowServer never calls it.
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#include <math.h>
static void fill(uint8_t *p, int S) { for (int y = 0; y < S; y++) for (int x = 0; x < S; x++) {
    double a = fabs((x + 0.5) / S * 2 - 1) / 0.8, b = fabs((y + 0.5) / S * 2 - 1) / 0.8; double f = pow(a, 5) + pow(b, 5), d = (pow(f, 0.2) - 1.0) * 0.8 * S * 0.5;
    double al = fmin(fmax(0.5 - d, 0.0), 1.0); uint8_t *q = p + ((size_t)y * S + x) * 4; q[0] = q[1] = q[2] = (uint8_t)(255 * al + 0.5); q[3] = (uint8_t)(255 * al + 0.5); } }
static double box_ref_err(uint8_t *out, int D, uint8_t *src, int S, int *mid)
{   // out is premultiplied BGRA; compare alpha channel with a box-filtered source alpha (area-average resample, exact for integer ratios, approximate otherwise)
    double se = 0; *mid = 0; for (int y = 0; y < D; y++) for (int x = 0; x < D; x++) {
        double x0 = (double)x * S / D, x1 = (double)(x + 1) * S / D, y0 = (double)y * S / D, y1 = (double)(y + 1) * S / D, s = 0, w = 0;
        for (int j = (int)floor(y0); j < (int)ceil(y1); j++) for (int i = (int)floor(x0); i < (int)ceil(x1); i++) { double ww = (fmin(i + 1, x1) - fmax(i, x0)) * (fmin(j + 1, y1) - fmax(j, y0)); s += ww * src[((size_t)j * S + i) * 4 + 3]; w += ww; }
        double ref = s / w; int a = out[((size_t)y * D + x) * 4 + 3]; se += fabs(a - ref); if (a > 0 && a < 255) (*mid)++; }
    return se / (D * D); }
int main(void) { @autoreleasepool {
    const int S = 1024; uint8_t *src = malloc((size_t)S * S * 4); fill(src, S);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    NSData *data = [NSData dataWithBytesNoCopy:src length:(size_t)S * S * 4 freeWhenDone:NO];
    CIImage *img = [CIImage imageWithBitmapData:data bytesPerRow:S * 4 size:CGSizeMake(S, S) format:kCIFormatBGRA8 colorSpace:cs];
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); printf("device %s\n", dev.name.UTF8String);
    CIContext *gpu = [CIContext contextWithMTLDevice:dev options:@{ kCIContextWorkingColorSpace: (__bridge id)cs, kCIContextOutputColorSpace: (__bridge id)cs }];
    CIContext *cpu = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES, kCIContextWorkingColorSpace: (__bridge id)cs, kCIContextOutputColorSpace: (__bridge id)cs }];
    int sizes[] = { 128, 112, 100, 64 }; int bad = 0;
    for (int k = 0; k < 4; k++) {
        int D = sizes[k]; double scale = (double)D / S;
        CIFilter *f = [CIFilter filterWithName:@"CILanczosScaleTransform"]; [f setValue:img forKey:kCIInputImageKey]; [f setValue:@(scale) forKey:kCIInputScaleKey]; [f setValue:@1.0 forKey:kCIInputAspectRatioKey];
        CIImage *o = f.outputImage; double e[2]; int m[2];
        for (int w = 0; w < 2; w++) {
            CIContext *c = w ? cpu : gpu; uint8_t *out = calloc((size_t)D * D, 4);
            [c render:o toBitmap:out rowBytes:D * 4 bounds:CGRectMake(0, 0, D, D) format:kCIFormatBGRA8 colorSpace:cs];
            e[w] = box_ref_err(out, D, src, S, &m[w]); free(out); }
        BOOL ok = e[0] < 3.0; if (!ok) bad++;
        printf("scale %.4f (%3d px): GPU mean abs err %6.2f in-between %5d | software renderer err %6.2f in-between %5d  %s\n", scale, D, e[0], m[0], e[1], m[1], ok ? "ok" : "GPU RESULT FAR FROM THE SMOOTH REFERENCE");
    }
    printf("%s\n", bad ? "FAIL" : "PASS"); return bad ? 1 : 0;
} }
