// cadence: poll a driver counter and report how evenly it increments (present cadence).
// usage: cadence [sysctl_name [seconds]]     default: debug.nvaccel_iop_ok 20
// build: clang -O2 -Wall -o cadence cadence.c
// exit: 0 stats printed; 1 the sysctl failed, or fewer than 5 increments; 2 seconds < 1
// output: bursts per second, then the gap between bursts in milliseconds
//   (mean, median, population stdev, p5, p95, p99, max). "extra increments hidden
//   inside a poll step" is ticks that arrived between two polls and so have no
//   gap of their own. >33 ms misses a 30 Hz slot; >50 ms and >100 ms are longer
//   stalls; <8 ms is two presents inside one 60 Hz refresh. The first line is the
//   poll step actually achieved (median). stdev divides by the number of gaps.
// permission: none. Reads a sysctl.
// cannot show: which process presented, whether the scanout tore, or jitter finer
//   than the poll step. The spin occupies one core for the whole run, so the
//   machine is not idle while this is measuring it.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>
#include <math.h>
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
int main(int argc, char **argv) {
    const char *name = argc > 1 ? argv[1] : "debug.nvaccel_iop_ok"; int secs = argc > 2 ? atoi(argv[2]) : 20;
    if (secs < 1) { fprintf(stderr, "usage: cadence [sysctl_name [seconds]]\n"); return 2; }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    static double t[400000], poll[400000]; static long dv[400000]; int n = 0, np = 0; long prev = 0; size_t sz = sizeof prev;
    if (sysctlbyname(name, &prev, &sz, NULL, 0)) { perror("sysctl"); return 1; }
    uint64_t start = mach_absolute_time(), end = start + (uint64_t)secs * 1000000000ull * tb.denom / tb.numer;
    // 0.1 ms of spinning between polls. nanosleep cannot hold a 0.5 ms wait: the
    // scheduler tick is about a millisecond and timer coalescing stretches it
    // further, which is a large slice of an 8-16 ms vblank, so the gaps used to
    // be quantised to that tick.
    uint64_t step = 100000ull * (uint64_t)tb.denom / (uint64_t)tb.numer; if (step < 1) step = 1;
    uint64_t prev_poll = start;
    while (n < 399999) {
        uint64_t now = mach_absolute_time(); if (now >= end) break;
        if (np < 399999) poll[np++] = (double)(now - prev_poll) * tb.numer / tb.denom / 1e6;
        prev_poll = now;
        long v = 0; sz = sizeof v; if (sysctlbyname(name, &v, &sz, NULL, 0)) { perror("sysctl"); return 1; }
        if (v != prev) { t[n] = (double)(now - start) * tb.numer / tb.denom / 1e6; dv[n] = v - prev; n++; prev = v; }
        uint64_t wake = now + step; while (mach_absolute_time() < wake) ;
    }
    if (n < 5) { printf("only %d increments of %s in %d s\n", n, name, secs); return 1; }
    if (np > 4) { qsort(poll, np, sizeof(double), cmp); printf("poll step ms: median %.3f over %d polls (one core spun the whole time)\n", poll[np / 2], np); }
    double iv[n]; long total = 0, multi = 0; for (int i = 0; i < n; i++) { total += dv[i]; if (dv[i] > 1) multi += dv[i] - 1; }
    for (int i = 1; i < n; i++) iv[i - 1] = t[i] - t[i - 1]; int m = n - 1; double sum = 0, mx = 0; for (int i = 0; i < m; i++) { sum += iv[i]; if (iv[i] > mx) mx = iv[i]; }
    double mean = sum / m, var = 0; for (int i = 0; i < m; i++) var += (iv[i] - mean) * (iv[i] - mean); double sorted[m]; memcpy(sorted, iv, sizeof sorted); qsort(sorted, m, sizeof(double), cmp);
    int over33 = 0, over50 = 0, over100 = 0, under8 = 0; for (int i = 0; i < m; i++) { if (iv[i] > 33.4) over33++; if (iv[i] > 50) over50++; if (iv[i] > 100) over100++; if (iv[i] < 8) under8++; }
    printf("%s over %d s: %ld increments in %d bursts (%.1f/s); %ld extra increments hidden inside a poll step\n", name, secs, total, n, n / (double)secs, multi);
    printf("interval ms: mean %.1f median %.1f stdev %.1f p5 %.1f p95 %.1f p99 %.1f max %.0f\n", mean, sorted[m / 2], sqrt(var / m), sorted[m / 20], sorted[m - m / 20 - 1], sorted[m - m / 100 - 1], mx);
    printf("gaps >33 ms: %d, >50 ms: %d, >100 ms: %d;  back-to-back (<8 ms): %d  (of %d)\n", over33, over50, over100, under8, m);
    return 0; }
