/*
 * NullMoth NVIDIA driver for macOS
 * Copyright (c) 2026 NullMoth Systems.
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#ifndef NVMTL_VT_RATECONTROL_H
#define NVMTL_VT_RATECONTROL_H
#include <stdint.h>

/* The closed encoder stores a QP at session+0x64 (CreateInstance writes 23) and
 * reloads it on every EncodeFrame. Both nve264_encode and nve265_encode clamp
 * it to 0..51. The HEVC Quality setter uses the same conversion below. This
 * controller stays in a narrower band: low enough that a static desktop is not
 * driven into mush, high enough that a busy 1080p frame can still hit a
 * typical stream target. Nothing here talks to VideoToolbox. */
enum {
    NVMTL_VT_RC_QP_MIN = 18,
    NVMTL_VT_RC_QP_MAX = 40,
    NVMTL_VT_RC_QP_START = 23
};

typedef struct nvmtl_vt_rc {
    double target_bps;
    double fps;
    double drain_bits;       /* bits the channel removes each frame */
    double capacity_bits;    /* virtual buffer, 1.25 s of target */
    double fullness_bits;    /* clamped to [0, capacity_bits] */
    int qp;                  /* QP to give the next frame */
} nvmtl_vt_rc;

static int nvmtl_vt_rc_clamp(int qp)
{
    if (qp < NVMTL_VT_RC_QP_MIN) return NVMTL_VT_RC_QP_MIN;
    if (qp > NVMTL_VT_RC_QP_MAX) return NVMTL_VT_RC_QP_MAX;
    return qp;
}

/* Half-full buffer and QP 23, which is what the library already uses before
 * any property is set. A non-positive target or frame rate leaves QP 23 and
 * disables the update (no divide by zero). */
static void nvmtl_vt_rc_init(nvmtl_vt_rc *rc, double target_bps, double fps)
{
    rc->target_bps = target_bps;
    rc->fps = fps;
    rc->qp = NVMTL_VT_RC_QP_START;
    if (!(target_bps > 0.0) || !(fps > 0.0)) {
        rc->drain_bits = 0.0;
        rc->capacity_bits = 0.0;
        rc->fullness_bits = 0.0;
        return;
    }
    rc->drain_bits = target_bps / fps;
    rc->capacity_bits = target_bps * 1.25;
    rc->fullness_bits = rc->capacity_bits * 0.5;
}

/* frame_bytes and is_idr describe the frame just produced at the previous QP.
 * The return value is the QP for the following frame.
 *
 * The buffer fills with the frame and drains by target_bps/fps. Fullness is
 * clamped, so a run of tiny static frames cannot pile up a deficit that would
 * later be spent as a bitrate spike, and one oversized frame cannot wind the
 * level without bound.
 *
 * QP steps by at most 1. A step up requires the frame itself to be over budget
 * (a high buffer left over from an IDR is not enough). A step down requires
 * the frame to be under budget. An IDR is added to the buffer and does not
 * step: the spike is one frame, and the P-frames after it do the correcting.
 * While fullness sits in the middle band and the frame is near the drain, QP
 * holds, which is what keeps a steady shot from hunting. */
static int nvmtl_vt_rc_update(nvmtl_vt_rc *rc, uint32_t frame_bytes, int is_idr)
{
    double bits, ratio, level;
    int step;

    if (!rc) return NVMTL_VT_RC_QP_START;
    if (!(rc->drain_bits > 0.0) || !(rc->capacity_bits > 0.0)) return rc->qp;
    bits = (double)frame_bytes * 8.0;
    rc->fullness_bits += bits - rc->drain_bits;
    if (rc->fullness_bits < 0.0) rc->fullness_bits = 0.0;
    if (rc->fullness_bits > rc->capacity_bits) rc->fullness_bits = rc->capacity_bits;
    if (is_idr) return rc->qp;
    ratio = bits / rc->drain_bits;
    level = rc->fullness_bits / rc->capacity_bits;
    step = 0;
    if (ratio > 1.40) step = 1;
    else if (ratio < 0.70 && level < 0.80) step = -1;
    else if (level > 0.72 && ratio > 1.04) step = 1;
    else if (level < 0.28 && ratio < 0.96) step = -1;
    rc->qp = nvmtl_vt_rc_clamp(rc->qp + step);
    return rc->qp;
}

/* Inverse of the library's SetProperty(Quality) conversion,
 *   qp = trunc(quality * -41 + 51 + 0.5)
 * (H.264 doubles at 0x83c0, 0x83c8, 0x83d0; HEVC at 0xac60, 0xac68, 0xac70).
 * The value sits 0.25 above the integer so a rounding error in the double
 * cannot fall into the next bin. Checked for every QP in [18, 40] by the
 * host test. Not sent to a session from here. */
static double nvmtl_vt_rc_quality_for_qp(int qp)
{
    return (51.25 - (double)qp) / 41.0;
}
#endif
