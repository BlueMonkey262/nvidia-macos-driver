// bench_nvenc: how fast does the hardware H.264 or HEVC encoder take frames through VideoToolbox? Opens a hardware session,
// feeds N synthetic NV12 frames in real-time mode and measures, over several runs: throughput (frames per second from the
// first submit to the last output), latency of each frame (submit to output callback: median, 95th percentile, worst) and
// CPU time per frame (user + system, whole process). A run includes session setup in none of the numbers.
// usage: [BENCH_CODEC=hevc] bench_nvenc [width height [frames [runs]]]   (H.264 unless BENCH_CODEC=hevc; HEVC needs the opt-in described in docs/HEVC.md)         default 1920 1080 300 5
// output: one "run" line per run, then   RESULT <w> <h> <fps median> <fps min> <p50 ms> <p95 ms> <max ms> <cpu ms/frame>
// build: clang -fobjc-arc -O1 -o bench_nvenc bench_nvenc.m -framework Foundation -framework VideoToolbox \
//          -framework CoreMedia -framework CoreVideo -framework Metal
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/resource.h>
#include <stdlib.h>

enum { RING = 8 };
static double *g_sub, *g_out;              // per frame: submit time and output time, ms
static _Atomic int g_done;
static CMVideoCodecType g_codec;

static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static double cpu_ms(void)
{
    struct rusage u; getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec * 1e3 + u.ru_utime.tv_usec / 1e3 + u.ru_stime.tv_sec * 1e3 + u.ru_stime.tv_usec / 1e3;
}
static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }

static CVPixelBufferRef make_frame(int w, int h, int i)
{
    CVPixelBufferRef pb = NULL;
    NSDictionary *attr = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)attr, &pb)) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *Y = CVPixelBufferGetBaseAddressOfPlane(pb, 0); size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
        Y[y * ys + x] = (uint8_t)(40 + (((x + 7 * i) % w) * 150) / w + 30 * ((((x + 3 * i) / 32) + (y / 32)) & 1) + (((x * y) >> 9) & 15));
    uint8_t *C = CVPixelBufferGetBaseAddressOfPlane(pb, 1); size_t cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int y = 0; y < h / 2; y++) for (int x = 0; x < w / 2; x++) { C[y * cs + 2 * x] = (uint8_t)(108 + (x * 40) / (w / 2)); C[y * cs + 2 * x + 1] = (uint8_t)(108 + (y * 40) / (h / 2)); }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static void cb(void *refcon, void *src, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb)
{
    intptr_t i = (intptr_t)src - 1;
    if (st || !sb || i < 0) return;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sb);
    if (!format || CMFormatDescriptionGetMediaSubType(format) != g_codec) {
        fprintf(stderr, "encoded sample codec differs from requested codec\n");
        return;
    }
    g_out[i] = now_ms();
    atomic_fetch_add(&g_done, 1);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        int w = argc > 2 ? atoi(argv[1]) : 1920, h = argc > 2 ? atoi(argv[2]) : 1080;
        int n = argc > 3 ? atoi(argv[3]) : 300, runs = argc > 4 ? atoi(argv[4]) : 5;
        g_codec = getenv("BENCH_CODEC") && !strcmp(getenv("BENCH_CODEC"), "hevc") ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
        printf("Requested codec: %s (checked against every encoded sample)\n", g_codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264");
        double load[1] = { 0 }; getloadavg(load, 1);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();    // brings the plugin up, which registers the encoder here
        printf("Metal device: %s   load average %.2f   %dx%d, %d frames, %d runs\n", dev ? dev.name.UTF8String : "(none)", load[0], w, h, n, runs);
        usleep(300000);
        CVPixelBufferRef ring[RING];
        for (int i = 0; i < RING; i++) ring[i] = make_frame(w, h, i);
        g_sub = calloc(n, sizeof(double)); g_out = calloc(n, sizeof(double));
        double fps[64], p50[64], p95[64], mx[64], cpu[64]; int ok = 0;
        for (int r = 0; r < runs && r < 64; r++) {
            atomic_store(&g_done, 0);
            VTCompressionSessionRef cs = NULL;
            NSDictionary *spec = @{ (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES };
            OSStatus st = VTCompressionSessionCreate(NULL, w, h, g_codec, (__bridge CFDictionaryRef)spec, NULL, NULL, cb, NULL, &cs);
            if (st || !cs) { printf("run %d: session create failed %d\n", r + 1, (int)st); continue; }
            VTSessionSetProperty(cs, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
            VTSessionSetProperty(cs, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
            VTSessionSetProperty(cs, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@60);
            VTCompressionSessionPrepareToEncodeFrames(cs);
            double c0 = cpu_ms(), t0 = now_ms();
            for (int i = 0; i < n; i++) {
                g_sub[i] = now_ms();
                OSStatus e = VTCompressionSessionEncodeFrame(cs, ring[i % RING], CMTimeMake(i, 60), CMTimeMake(1, 60), NULL, (void *)(intptr_t)(i + 1), NULL);
                if (e) { printf("run %d: EncodeFrame %d -> %d\n", r + 1, i, (int)e); break; }
            }
            VTCompressionSessionCompleteFrames(cs, kCMTimeInvalid);
            double t1 = now_ms(), c1 = cpu_ms();
            VTCompressionSessionInvalidate(cs); CFRelease(cs);
            int got = atomic_load(&g_done);
            if (got < n) { printf("run %d: only %d of %d frames came out\n", r + 1, got, n); continue; }
            double *lat = malloc(n * sizeof(double)); double last = 0;
            for (int i = 0; i < n; i++) { lat[i] = g_out[i] - g_sub[i]; if (g_out[i] > last) last = g_out[i]; }
            qsort(lat, n, sizeof(double), cmp);
            fps[ok] = n / ((last - t0) / 1e3); p50[ok] = lat[n / 2]; p95[ok] = lat[(int)(n * 0.95)]; mx[ok] = lat[n - 1]; cpu[ok] = (c1 - c0) / n;
            printf("run %d: %.0f fps, latency p50 %.2f ms p95 %.2f ms max %.2f ms, cpu %.2f ms/frame (wall %.0f ms)\n", r + 1, fps[ok], p50[ok], p95[ok], mx[ok], cpu[ok], t1 - t0);
            free(lat); ok++;
            usleep(200000);
        }
        if (!ok) { printf("no run completed\n"); return 2; }
        double sf[64], sp50[64], sp95[64], smx[64], scpu[64];
        memcpy(sf, fps, sizeof(double) * ok); memcpy(sp50, p50, sizeof(double) * ok); memcpy(sp95, p95, sizeof(double) * ok); memcpy(smx, mx, sizeof(double) * ok); memcpy(scpu, cpu, sizeof(double) * ok);
        qsort(sf, ok, sizeof(double), cmp); qsort(sp50, ok, sizeof(double), cmp); qsort(sp95, ok, sizeof(double), cmp); qsort(smx, ok, sizeof(double), cmp); qsort(scpu, ok, sizeof(double), cmp);
        printf("RESULT %d %d %.0f %.0f %.2f %.2f %.2f %.2f\n", w, h, sf[ok / 2], sf[0], sp50[ok / 2], sp95[ok / 2], smx[ok - 1], scpu[ok / 2]);
    }
    return 0;
}
