#!/usr/bin/env python3
"""Host test for plugin/nvmtl_vt_ratecontrol.h.

Compiles the header with cc on this machine and runs a simulated encoder.
The size model is the measured constant-QP point from the codec notes: QP 23
on busy 1080p is about 68 Mbit/s, and six QP steps halve the rate. An IDR is
five times a P-frame of the same QP. The target is 18 Mbit/s at 60 fps.

Models: steady motion, scene cuts, periodic IDR spikes, a static desktop with
short bursts. After a warm-up, 10 s windows of the first three must land
within ±15% of the target. QP stays in [18, 40], moves by at most 1 per frame,
and on a settled constant-complexity stretch spans at most 4 (a swing of ±2).
Buffer fullness stays inside the virtual buffer. Static frames are too small
to spend 18 Mbit/s even at QP 18, so those windows must stay under the target
and the quiet stretch must sit on QP 18.

Negative control: the same steady model with a controller that always returns
QP 23 (what the library does today). That must miss the ±15% window.
Exit 0 on pass, 1 on fail. Nothing here loads the encoder or runs on macOS.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HEADER = ROOT / "plugin" / "nvmtl_vt_ratecontrol.h"
CC = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")

DRIVER = r'''
#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include "nvmtl_vt_ratecontrol.h"

enum { FPS = 60, SECS = 40, N = FPS * SECS };
static const double TARGET = 18000000.0;
static const double ANCHOR = 68000000.0;   /* QP 23, complexity 1, busy 1080p */

static int fails = 0;
static void check(const char *name, int ok, const char *detail)
{
    const char *tag = ok ? "ok   " : "FAIL ";
    if (detail && detail[0]) printf("%s%s (%s)\n", tag, name, detail);
    else printf("%s%s\n", tag, name);
    if (!ok) fails++;
}

static double scale(int qp)
{
    return pow(2.0, -((double)qp - 23.0) / 6.0);
}

static uint32_t frame_bytes(int qp, double comp, int idr)
{
    double bits = ANCHOR * comp * scale(qp) / (double)FPS;
    if (idr) bits *= 5.0;
    if (bits < 8.0) bits = 8.0;
    return (uint32_t)(bits / 8.0 + 0.5);
}

typedef int (*rc_update_fn)(nvmtl_vt_rc *rc, uint32_t bytes, int idr);

static int real_update(nvmtl_vt_rc *rc, uint32_t bytes, int idr)
{
    return nvmtl_vt_rc_update(rc, bytes, idr);
}

/* What the library does now: the measured size never moves the QP. */
static int broken_update(nvmtl_vt_rc *rc, uint32_t bytes, int idr)
{
    (void)rc; (void)bytes; (void)idr;
    return NVMTL_VT_RC_QP_START;
}

struct run {
    int qp[N];
    double bits[N];
    double level[N];
    int max_step;
    int qp_lo, qp_hi;
    int level_bad;
};

static void simulate(struct run *o, rc_update_fn upd,
                     double (*comp_of)(int), int (*idr_of)(int))
{
    nvmtl_vt_rc rc;
    int i, qp, prev;
    nvmtl_vt_rc_init(&rc, TARGET, (double)FPS);
    qp = rc.qp;
    prev = qp;
    o->max_step = 0;
    o->qp_lo = 99;
    o->qp_hi = -1;
    o->level_bad = 0;
    for (i = 0; i < N; i++) {
        int idr = idr_of(i);
        uint32_t bytes = frame_bytes(qp, comp_of(i), idr);
        int step;
        o->qp[i] = qp;
        o->bits[i] = (double)bytes * 8.0;
        qp = upd(&rc, bytes, idr);
        step = qp - prev;
        if (step < 0) step = -step;
        if (step > o->max_step) o->max_step = step;
        prev = qp;
        if (o->qp[i] < o->qp_lo) o->qp_lo = o->qp[i];
        if (o->qp[i] > o->qp_hi) o->qp_hi = o->qp[i];
        o->level[i] = (rc.capacity_bits > 0.0) ? rc.fullness_bits / rc.capacity_bits : -1.0;
        if (rc.fullness_bits < -1e-6 || rc.fullness_bits > rc.capacity_bits + 1e-3) o->level_bad = 1;
    }
}

/* 10 s windows after warm-up. Returns how many windows fell outside ±tol.
 * *lo_mbps / *hi_mbps are the window rates actually seen. */
static int windows(const struct run *o, int warmup_s, double tol, double *lo_mbps, double *hi_mbps)
{
    int start = warmup_s * FPS, win = 10 * FPS, i, bad = 0, nwin = 0;
    *lo_mbps = 1e300;
    *hi_mbps = 0.0;
    for (i = start; i + win <= N; i += win) {
        double sum = 0.0, mbps;
        int j;
        for (j = 0; j < win; j++) sum += o->bits[i + j];
        mbps = (sum / 10.0) / 1e6;
        if (mbps < *lo_mbps) *lo_mbps = mbps;
        if (mbps > *hi_mbps) *hi_mbps = mbps;
        if (mbps < (TARGET / 1e6) * (1.0 - tol) || mbps > (TARGET / 1e6) * (1.0 + tol)) bad++;
        nwin++;
    }
    if (nwin < 2) return 99;
    return bad;
}

static int qp_span(const struct run *o, int a, int b)
{
    int lo = 99, hi = -1, i;
    for (i = a; i < b; i++) {
        if (o->qp[i] < lo) lo = o->qp[i];
        if (o->qp[i] > hi) hi = o->qp[i];
    }
    return hi - lo;
}

static double comp_steady(int i) { (void)i; return 1.0; }
static int idr_steady(int i) { return i % (2 * FPS) == 0; }
static double comp_scene(int i) { return ((i / (2 * FPS)) % 2 == 0) ? 1.50 : 0.62; }
static int idr_scene(int i) { return i % (2 * FPS) == 0; }
static double comp_static(int i) { return (i % (3 * FPS) < 5) ? 1.6 : 0.02; }
static int idr_static(int i) { return i % (3 * FPS) == 0; }
static int idr_every(int i) { return i % FPS == 0; }

static void report_rate(const char *name, const struct run *o, int want_inside)
{
    double lo, hi;
    int bad = windows(o, 4, 0.15, &lo, &hi);
    char detail[96];
    snprintf(detail, sizeof detail, "%.2f..%.2f Mbit/s", lo, hi);
    if (want_inside) check(name, bad == 0, detail);
    else check(name, bad > 0, detail);
}

int main(void)
{
    struct run steady, scene, idr, stat, broken;
    int qp, seg, quiet_bad = 0, seg_bad = 0, moved = 0;
    char detail[96];

    for (qp = NVMTL_VT_RC_QP_MIN; qp <= NVMTL_VT_RC_QP_MAX; qp++) {
        double q = nvmtl_vt_rc_quality_for_qp(qp);
        double pre = q * -41.0 + 51.0 + 0.5;
        int got = (int)pre;   /* trunc toward 0, pre is positive: matches cvttsd2si */
        if (got != qp || q <= 0.0 || q >= 1.0) {
            snprintf(detail, sizeof detail, "qp %d -> quality %.6f -> %d", qp, q, got);
            check("Quality double round-trips through the library formula", 0, detail);
            break;
        }
    }
    if (qp > NVMTL_VT_RC_QP_MAX)
        check("Quality double round-trips for QP 18..40", 1, "trunc(q*-41+51.5) == qp");

    simulate(&steady, real_update, comp_steady, idr_steady);
    simulate(&scene, real_update, comp_scene, idr_scene);
    simulate(&idr, real_update, comp_steady, idr_every);
    simulate(&stat, real_update, comp_static, idr_static);
    simulate(&broken, broken_update, comp_steady, idr_steady);

    check("steady: first frame uses the library default QP 23", steady.qp[0] == 23, "");
    report_rate("steady: 10 s windows within ±15% of 18 Mbit/s", &steady, 1);
    report_rate("scene cuts: 10 s windows within ±15% of 18 Mbit/s", &scene, 1);
    report_rate("IDR every second: 10 s windows within ±15% of 18 Mbit/s", &idr, 1);

    snprintf(detail, sizeof detail, "steady %d..%d, idr %d..%d",
             steady.qp_lo, steady.qp_hi, idr.qp_lo, idr.qp_hi);
    check("QP never leaves [18, 40]",
          steady.qp_lo >= 18 && steady.qp_hi <= 40 &&
          scene.qp_lo >= 18 && scene.qp_hi <= 40 &&
          idr.qp_lo >= 18 && idr.qp_hi <= 40 &&
          stat.qp_lo >= 18 && stat.qp_hi <= 40, detail);

    snprintf(detail, sizeof detail, "steady %d, scene %d, idr %d, static %d",
             steady.max_step, scene.max_step, idr.max_step, stat.max_step);
    check("QP step is at most 1 per frame",
          steady.max_step <= 1 && scene.max_step <= 1 && idr.max_step <= 1 && stat.max_step <= 1,
          detail);

    /* Settled constant shot: ignore the first 4 s, then the swing is at most ±2. */
    {
        int span_s = qp_span(&steady, 4 * FPS, N);
        int span_i = qp_span(&idr, 4 * FPS, N);
        snprintf(detail, sizeof detail, "steady span %d, idr span %d", span_s, span_i);
        check("steady state: QP oscillation within ±2", span_s <= 4 && span_i <= 4, detail);
    }

    /* Each 2 s scene, after 30 frames of settling, stays inside ±2.
     * The high-complexity scenes must also sit above the low ones. */
    for (seg = 2; seg < SECS / 2; seg++) {
        int a = seg * 2 * FPS + 30;
        int b = (seg + 1) * 2 * FPS;
        int span = qp_span(&scene, a, b);
        if (span > 4) seg_bad++;
    }
    {
        int hi_lo = 99, lo_hi = -1, i;
        /* Skip the first 30 frames of each scene: QP is still walking over. */
        for (i = 6 * FPS; i < N; i++) {
            int into = i % (2 * FPS);
            int hi = ((i / (2 * FPS)) % 2) == 0;
            if (into < 30) continue;
            if (hi && scene.qp[i] < hi_lo) hi_lo = scene.qp[i];
            if (!hi && scene.qp[i] > lo_hi) lo_hi = scene.qp[i];
        }
        moved = hi_lo >= lo_hi + 2;
        snprintf(detail, sizeof detail, "bad stretches %d, high-scene min %d, low-scene max %d",
                 seg_bad, hi_lo, lo_hi);
    }
    check("scene cuts: settled stretch within ±2, and QP does move between scenes",
          seg_bad == 0 && moved, detail);

    check("buffer fullness stays inside the virtual buffer",
          !steady.level_bad && !scene.level_bad && !idr.level_bad && !stat.level_bad, "");

    /* Quiet frames of the static model: not the 5-frame burst, and not the
     * few frames QP needs to walk back to the floor. */
    for (qp = 8 * FPS; qp < 30 * FPS; qp++) {
        if ((qp % (3 * FPS)) >= 45 && stat.qp[qp] != 18) quiet_bad++;
    }
    snprintf(detail, sizeof detail, "%d quiet frames not at QP 18", quiet_bad);
    check("static desktop: quiet stretch sits on QP 18", quiet_bad == 0, detail);
    {
        double lo, hi;
        int bad_hi = windows(&stat, 4, 0.15, &lo, &hi);
        /* windows() counts either side. Recompute the high side only. */
        int start = 4 * FPS, win = 10 * FPS, i, over = 0;
        (void)bad_hi;
        lo = 1e300; hi = 0;
        for (i = start; i + win <= N; i += win) {
            double sum = 0, mbps;
            int j;
            for (j = 0; j < win; j++) sum += stat.bits[i + j];
            mbps = (sum / 10.0) / 1e6;
            if (mbps < lo) lo = mbps;
            if (mbps > hi) hi = mbps;
            if (mbps > (TARGET / 1e6) * 1.15) over++;
        }
        snprintf(detail, sizeof detail, "%.2f..%.2f Mbit/s", lo, hi);
        check("static desktop: 10 s windows stay under the target (no filler) and within +15%",
              over == 0 && hi < (TARGET / 1e6) * 0.85, detail);
    }

    report_rate("negative control: constant QP 23 misses the ±15% window", &broken, 0);
    snprintf(detail, sizeof detail, "qp %d..%d", broken.qp_lo, broken.qp_hi);
    check("negative control: broken controller really held QP 23",
          broken.qp_lo == 23 && broken.qp_hi == 23, detail);

    printf(fails ? "FAILED\n" : "PASS\n");
    return fails ? 1 : 0;
}
'''


def main():
    text = HEADER.read_text()
    includes = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("#include")]
    banned = ("CoreFoundation", "VideoToolbox", "Cocoa", "objc/", "TargetConditionals")
    bad = [b for b in banned if any(b in inc for inc in includes)]
    if bad:
        print("FAIL header pulls in Apple headers: " + ", ".join(bad))
        return 1
    if not CC:
        print("FAIL no C compiler (cc) on this machine")
        return 1
    with tempfile.TemporaryDirectory() as td:
        src = pathlib.Path(td) / "rc_test.c"
        exe = pathlib.Path(td) / "rc_test"
        src.write_text(DRIVER)
        cmd = [CC, "-std=c99", "-Wall", "-Wextra", "-Werror", "-O2",
               "-I", str(ROOT / "plugin"), str(src), "-o", str(exe), "-lm"]
        built = subprocess.run(cmd, capture_output=True, text=True)
        print("compile:", " ".join(cmd))
        if built.returncode != 0:
            print(built.stderr)
            print("FAIL header did not compile")
            return 1
        print("ok   nvmtl_vt_ratecontrol.h compiles as C99")
        ran = subprocess.run([str(exe)], capture_output=True, text=True)
        sys.stdout.write(ran.stdout)
        if ran.stderr:
            sys.stderr.write(ran.stderr)
        if "PASS" not in ran.stdout or "negative control" not in ran.stdout:
            print("FAIL driver did not report PASS and the negative control")
            return 1
        return ran.returncode


if __name__ == "__main__":
    sys.exit(main())
