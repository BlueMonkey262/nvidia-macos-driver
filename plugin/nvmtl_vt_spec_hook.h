// VideoToolbox refuses to open a hardware H.264 session that asks for EnableLowLatencyRateControl when the GPU is not
// one of Apple's: that rate control lives in VideoProcessing ("VCPRateControlSession: Hardware support is not
// available") and the call fails with -12902 (kVTParameterErr), also for VTCopySupportedPropertyDictionaryForEncoder.
// ffmpeg's h264_videotoolbox adds the key whenever it is in low-delay mode, which Sunshine always is, so Sunshine
// could not open our encoder and fell back to software x264.
// Our encoder runs at constant QP and does not use that rate-control layer, so in a process where it is registered the
// key is removed from the specification before the call reaches VideoToolbox. Calls are redirected by rebinding the
// symbol pointers of every loaded image (and of images loaded later), the way fishhook does.
// Second problem, same hook: ffmpeg opens a session and then calls VTCopySupportedPropertyDictionaryForEncoder with the
// session still open. VideoToolbox answers that by instantiating the encoder, our library allows one engine per process
// and refuses (upstream issue #206), so the lookup fails with -12908 (kVTCouldNotFindVideoEncoderErr) and ffmpeg gives up.
// The dictionary does not depend on the session, so it is fetched once right before the first hardware H.264 session is
// created (no session open yet) and served from the cache when a later lookup fails that way.
// HEVC is the same two calls: ffmpeg's hevc_videotoolbox adds EnableLowLatencyRateControl too, and VideoToolbox refuses it on a
// GPU that is not Apple's (-12902). Both codecs are handled; H.264 and HEVC registration each call nvmtl_vt_spec_hook_install,
// which still runs once.
// NVMTL_NO_VT_SPEC_HOOK=1 turns it off.
// Third part, opt-in with NVMTL_VT_RC=1: bitrate control. The encoder library runs at a constant QP and ignores
// AverageBitRate, but it re-reads its QP for every frame and SetProperty(Quality) writes it. For a hardware H.264 or HEVC session
// the output callback is wrapped to see every encoded frame's size, nvmtl_vt_ratecontrol.h turns those sizes and the
// AverageBitRate / ExpectedFrameRate seen through a rebind of VTSessionSetProperty into the next QP, and the quality for
// it is set through the original VTSessionSetProperty (so it does not pass through the hook again).
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include "nvmtl_vt_ratecontrol.h"

typedef int32_t (*nvmtl_vt_create_fn)(CFAllocatorRef, int32_t, int32_t, uint32_t, CFDictionaryRef, CFDictionaryRef,
                                      CFAllocatorRef, void *, void *, void *);
typedef int32_t (*nvmtl_vt_props_fn)(int32_t, int32_t, uint32_t, CFDictionaryRef, CFStringRef *, CFDictionaryRef *);
static nvmtl_vt_create_fn g_vt_create_orig;
static nvmtl_vt_props_fn g_vt_props_orig;

// --- bitrate control (opt-in, see the header comment) ---
typedef void (*nvmtl_vt_out_cb)(void *refcon, void *src, int32_t status, uint32_t flags, CFTypeRef sample);
typedef int32_t (*nvmtl_vt_setprop_fn)(CFTypeRef session, CFStringRef key, CFTypeRef value);
typedef int32_t (*nvmtl_vt_copyprop_fn)(CFTypeRef session, CFStringRef key, CFAllocatorRef a, void *out);
typedef size_t (*nvmtl_cm_size_fn)(CFTypeRef sample);
typedef CFArrayRef (*nvmtl_cm_att_fn)(CFTypeRef sample, bool create);
static nvmtl_vt_setprop_fn g_vt_setprop_orig;
static nvmtl_vt_copyprop_fn g_vt_copyprop;
static nvmtl_cm_size_fn g_cm_size;
static nvmtl_cm_att_fn g_cm_att;
static int g_rc_enabled;
typedef struct nvmtl_vt_rcs {
    CFTypeRef session;
    nvmtl_vt_out_cb cb;
    void *refcon;
    nvmtl_vt_rc rc;
    double bps, fps;
    int active, started, last_qp;
} nvmtl_vt_rcs;
enum { NVMTL_VT_RC_SESSIONS = 8 };
static pthread_mutex_t g_rcs_lock = PTHREAD_MUTEX_INITIALIZER;
static nvmtl_vt_rcs *g_rcs[NVMTL_VT_RC_SESSIONS];
static unsigned g_rcs_next;   // the slot the next session takes: the oldest entry is replaced, so a long-lived process never runs out

// The wrapper the session calls instead of the client's callback: measure the frame, steer QP, pass the frame on.
static void nvmtl_vt_rc_output(void *p, void *src, int32_t status, uint32_t flags, CFTypeRef sample)
{
    nvmtl_vt_rcs *c = (nvmtl_vt_rcs *)p;
    if (!status && sample) {
        const size_t bytes = g_cm_size(sample);
        int idr = 1;   // a sample with no NotSync attachment is a sync (key) frame
        CFArrayRef att = g_cm_att(sample, false);
        if (att && CFArrayGetCount(att) > 0) {
            CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(att, 0);
            const void *ns = d ? CFDictionaryGetValue(d, CFSTR("NotSync")) : NULL;
            if (ns && CFGetTypeID(ns) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)ns)) idr = 0;
        }
        int change = 0, qp = 0;
        pthread_mutex_lock(&g_rcs_lock);
        if (c->active && !c->started && c->bps > 0.0) { nvmtl_vt_rc_init(&c->rc, c->bps, c->fps > 0.0 ? c->fps : 60.0); c->started = 1; c->last_qp = c->rc.qp; }
        if (c->active && c->started) { qp = nvmtl_vt_rc_update(&c->rc, (uint32_t)bytes, idr); change = qp != c->last_qp; c->last_qp = qp; }
        pthread_mutex_unlock(&g_rcs_lock);
        if (change) {
            double q = nvmtl_vt_rc_quality_for_qp(qp);
            CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &q);
            if (n) { g_vt_setprop_orig(c->session, CFSTR("Quality"), n); CFRelease(n); }
        }
    }
    if (c->cb) c->cb(c->refcon, src, status, flags, sample);
}
// VTSessionSetProperty: remember AverageBitRate and ExpectedFrameRate of a session under bitrate control, then pass on.
static int32_t nvmtl_vt_setprop_hook(CFTypeRef session, CFStringRef key, CFTypeRef value)
{
    const int32_t r = g_vt_setprop_orig(session, key, value);
    if (r == 0 && session && key && value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        const int which = CFEqual(key, CFSTR("AverageBitRate")) ? 1 : CFEqual(key, CFSTR("ExpectedFrameRate")) ? 2 : 0;
        double v = 0.0;
        if (which && CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &v)) {
            pthread_mutex_lock(&g_rcs_lock);
            for (int i = 0; i < NVMTL_VT_RC_SESSIONS; i++)
                if (g_rcs[i] && g_rcs[i]->session == session) {
                    if (which == 1) g_rcs[i]->bps = v; else g_rcs[i]->fps = v;
                    g_rcs[i]->started = 0;   // the controller restarts from the new target at the next frame
                }
            pthread_mutex_unlock(&g_rcs_lock);
        }
    }
    return r;
}

// A retained copy of spec without the low-latency key (or spec itself, retained, when it has none).
static CFDictionaryRef nvmtl_vt_spec_without_lowlatency(uint32_t codec, CFDictionaryRef spec)
{
    if (!spec) return NULL;
    if ((codec != 'avc1' && codec != 'hvc1') || !CFDictionaryContainsKey(spec, CFSTR("EnableLowLatencyRateControl"))) return CFRetain(spec);
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, spec);
    if (!m) return CFRetain(spec);   // out of memory: pass the original on rather than crash
    CFDictionaryRemoveValue(m, CFSTR("EnableLowLatencyRateControl"));
    nvlog("nvenc: dropped EnableLowLatencyRateControl from an %s specification in %s", codec == 'hvc1' ? "HEVC" : "H.264", getprogname());
    return m;
}
// The supported-property dictionaries of our encoders, one per codec ('avc1' H.264, 'hvc1' HEVC) and frame size (what the
// encoder reports can depend on both), so a failed HEVC lookup can never be answered with the H.264 dictionary.
enum { NVMTL_VT_CACHE_ENTRIES = 8 };
static pthread_mutex_t g_vt_cache_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_vt_prime_lock = PTHREAD_MUTEX_INITIALIZER;   // one priming lookup at a time (the engine is one per process)
static struct { uint32_t codec; int32_t w, h; CFStringRef id; CFDictionaryRef props; } g_vt_cache[NVMTL_VT_CACHE_ENTRIES];
static unsigned g_vt_cache_next;
enum { NVMTL_VT_COULD_NOT_FIND_ENCODER = -12908 };

static bool nvmtl_vt_codec_cached(uint32_t codec) { return codec == 'avc1' || codec == 'hvc1'; }
// The index of the entry for this codec and size, or -1. Call with g_vt_cache_lock held.
static int nvmtl_vt_cache_find(uint32_t codec, int32_t w, int32_t h)
{
    for (int i = 0; i < NVMTL_VT_CACHE_ENTRIES; i++)
        if (g_vt_cache[i].props && g_vt_cache[i].codec == codec && g_vt_cache[i].w == w && g_vt_cache[i].h == h) return i;
    return -1;
}
// Keep the answer when it came from our encoder for this codec; a later answer for the same codec and size replaces the earlier one.
static void nvmtl_vt_cache_store(uint32_t codec, int32_t w, int32_t h, CFStringRef encoderID, CFDictionaryRef props)
{
    if (!nvmtl_vt_codec_cached(codec) || !encoderID || !props) return;
    CFStringRef want = codec == 'hvc1' ? CFSTR("com.nvmtl.videoencoder.hevc.nvenc") : CFSTR("com.nvmtl.videoencoder.avc.nvenc");
    if (CFStringCompare(encoderID, want, 0) != kCFCompareEqualTo) return;
    CFRetain(encoderID); CFRetain(props);
    pthread_mutex_lock(&g_vt_cache_lock);
    int i = nvmtl_vt_cache_find(codec, w, h);
    if (i < 0) i = (int)(g_vt_cache_next++ % NVMTL_VT_CACHE_ENTRIES);
    CFStringRef old_id = g_vt_cache[i].id; CFDictionaryRef old_props = g_vt_cache[i].props;
    g_vt_cache[i].codec = codec; g_vt_cache[i].w = w; g_vt_cache[i].h = h; g_vt_cache[i].id = encoderID; g_vt_cache[i].props = props;
    pthread_mutex_unlock(&g_vt_cache_lock);
    if (old_id) CFRelease(old_id);
    if (old_props) CFRelease(old_props);
}
// One lookup for each codec and frame size, made right before a hardware session of that kind is created (no session open yet).
static void nvmtl_vt_cache_prime(int32_t w, int32_t h, uint32_t codec, CFDictionaryRef spec)
{
    if (!nvmtl_vt_codec_cached(codec) || !spec || !g_vt_props_orig) return;
    pthread_mutex_lock(&g_vt_prime_lock);   // two creates at once do not both ask the encoder
    pthread_mutex_lock(&g_vt_cache_lock);
    const bool have = nvmtl_vt_cache_find(codec, w, h) >= 0;
    pthread_mutex_unlock(&g_vt_cache_lock);
    if (!have) {
        CFStringRef id = NULL; CFDictionaryRef props = NULL;
        int32_t pr = g_vt_props_orig(w, h, codec, spec, &id, &props);
        nvlog("nvenc: primed the %s supported-property cache in %s: %dx%d -> %d", codec == 'hvc1' ? "HEVC" : "H.264", getprogname(), (int)w, (int)h, (int)pr);
        if (pr == 0) nvmtl_vt_cache_store(codec, w, h, id, props);
        if (id) CFRelease(id);
        if (props) CFRelease(props);
    }
    pthread_mutex_unlock(&g_vt_prime_lock);
}
static int32_t nvmtl_vt_create_hook(CFAllocatorRef a, int32_t w, int32_t h, uint32_t codec, CFDictionaryRef spec,
                                    CFDictionaryRef attrs, CFAllocatorRef ca, void *cb, void *refcon, void *out)
{
    CFDictionaryRef s = nvmtl_vt_spec_without_lowlatency(codec, spec);
    nvmtl_vt_cache_prime(w, h, codec, s);
    nvmtl_vt_rcs *ctx = NULL;
    void *use_cb = cb, *use_ref = refcon;
    if (g_rc_enabled && nvmtl_vt_codec_cached(codec) && cb && out) {
        ctx = (nvmtl_vt_rcs *)calloc(1, sizeof *ctx);
        if (ctx) { ctx->cb = (nvmtl_vt_out_cb)cb; ctx->refcon = refcon; use_cb = (void *)nvmtl_vt_rc_output; use_ref = ctx; }
    }
    int32_t r = g_vt_create_orig(a, w, h, codec, s, attrs, ca, use_cb, use_ref, out);
    if (nvmtl_vt_codec_cached(codec)) nvlog("nvenc: VTCompressionSessionCreate %dx%d %s in %s -> %d", (int)w, (int)h, codec == 'hvc1' ? "HEVC" : "H.264", getprogname(), (int)r);
    if (s) CFRelease(s);
    if (ctx) {
        CFTypeRef session = r == 0 ? *(CFTypeRef *)out : NULL;
        CFTypeRef hw = NULL;
        if (session && g_vt_copyprop && g_vt_copyprop(session, CFSTR("UsingHardwareAcceleratedVideoEncoder"), NULL, &hw) == 0 && hw == kCFBooleanTrue) {
            pthread_mutex_lock(&g_rcs_lock);
            // An entry for the same session address belongs to a session that has gone: drop it so it cannot shadow this
            // one. The oldest entry is replaced when the table is full. Replaced contexts are not freed: the session that
            // owns one may still deliver a frame to it (a few bytes per session stay allocated).
            for (int i = 0; i < NVMTL_VT_RC_SESSIONS; i++)
                if (g_rcs[i] && g_rcs[i]->session == session) { g_rcs[i]->active = 0; g_rcs[i] = NULL; }
            const unsigned slot = g_rcs_next++ % NVMTL_VT_RC_SESSIONS;
            if (g_rcs[slot]) g_rcs[slot]->active = 0;
            ctx->session = session; ctx->active = 1; g_rcs[slot] = ctx;
            pthread_mutex_unlock(&g_rcs_lock);
            nvlog("nvenc: bitrate control on for a %dx%d %s hardware session in %s", (int)w, (int)h,
                  codec == 'hvc1' ? "HEVC" : "H.264", getprogname());
        }
        if (hw) CFRelease(hw);
        // The context is never freed: the session may still deliver a frame to it after a failed or finished create, and a
        // session that is not ours keeps it as a plain pass-through. It costs a few dozen bytes per session.
    }
    return r;
}
static int32_t nvmtl_vt_props_hook(int32_t w, int32_t h, uint32_t codec, CFDictionaryRef spec, CFStringRef *idOut,
                                   CFDictionaryRef *propsOut)
{
    CFDictionaryRef s = nvmtl_vt_spec_without_lowlatency(codec, spec);
    int32_t r = g_vt_props_orig(w, h, codec, s, idOut, propsOut);
    if (s) CFRelease(s);
    if (nvmtl_vt_codec_cached(codec)) nvlog("nvenc: VTCopySupportedPropertyDictionaryForEncoder %dx%d %s in %s -> %d", (int)w, (int)h, codec == 'hvc1' ? "HEVC" : "H.264", getprogname(), (int)r);
    if (r == 0) { if (nvmtl_vt_codec_cached(codec) && idOut && *idOut && propsOut && *propsOut) nvmtl_vt_cache_store(codec, w, h, *idOut, *propsOut); return r; }
    if (r == NVMTL_VT_COULD_NOT_FIND_ENCODER && nvmtl_vt_codec_cached(codec) && propsOut) {   // ffmpeg passes no encoder-ID output
        // answered only from an entry for this very codec and size: another size or codec keeps its error
        pthread_mutex_lock(&g_vt_cache_lock);
        const int i = nvmtl_vt_cache_find(codec, w, h);
        if (i >= 0) {
            if (idOut) *idOut = CFRetain(g_vt_cache[i].id);
            *propsOut = CFRetain(g_vt_cache[i].props);
            r = 0;
            nvlog("nvenc: served the cached supported-property dictionary in %s (an encoder session is open)", getprogname());
        }
        pthread_mutex_unlock(&g_vt_cache_lock);
    }
    return r;
}

#ifndef MH_DYLIB_IN_CACHE
#define MH_DYLIB_IN_CACHE 0x80000000u
#endif
static void nvmtl_vt_rebind_image(const struct mach_header *mh, intptr_t slide)
{
    if (!mh || mh->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *hdr = (const struct mach_header_64 *)mh;
    // Images of the dyld shared cache (system frameworks) are left alone: their pointer pages are not ours to write, and
    // the calls that matter (ffmpeg, Sunshine, apps) come from images outside the cache.
    if (hdr->flags & MH_DYLIB_IN_CACHE) return;
    const struct symtab_command *st = NULL;
    const struct dysymtab_command *dst = NULL;
    const struct segment_command_64 *linkedit = NULL;
    // The load commands lie in [cmds, cmds_end). A command smaller than its own header, or one that runs past the end,
    // ends the walk: an image that dyld accepted should never have either, but this runs in every process.
    const char *cmds = (const char *)(hdr + 1), *cmds_end = cmds + hdr->sizeofcmds;
    const struct load_command *lc = (const struct load_command *)cmds;
    for (uint32_t i = 0; i < hdr->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
        if ((const char *)lc + sizeof *lc > cmds_end || lc->cmdsize < sizeof *lc || (const char *)lc + lc->cmdsize > cmds_end) break;
        if (lc->cmd == LC_SYMTAB) st = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dst = (const struct dysymtab_command *)lc;
        else if (lc->cmd == LC_SEGMENT_64 && !strncmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT, 16))
            linkedit = (const struct segment_command_64 *)lc;
    }
    if (!st || !dst || !linkedit || !dst->nindirectsyms) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const struct nlist_64 *)(base + st->symoff);
    const char *strs = (const char *)(base + st->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dst->indirectsymoff);
    lc = (const struct load_command *)cmds;
    for (uint32_t i = 0; i < hdr->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
        if ((const char *)lc + sizeof *lc > cmds_end || lc->cmdsize < sizeof *lc || (const char *)lc + lc->cmdsize > cmds_end) break;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        // the sections must fit inside the command
        if (lc->cmdsize < sizeof *seg || (lc->cmdsize - sizeof *seg) / sizeof(struct section_64) < seg->nsects) continue;
        const bool is_const = !strncmp(seg->segname, "__DATA_CONST", 16);
        if (strncmp(seg->segname, SEG_DATA, 16) && !is_const) continue;   // __AUTH_CONST holds signed pointers: not touched
        const struct section_64 *sec = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sec++) {
            uint32_t type = sec->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)((uintptr_t)slide + sec->addr);
            const uint32_t *idx = indirect + sec->reserved1;
            for (uint64_t k = 0; k < sec->size / sizeof(void *); k++) {
                if ((uint64_t)sec->reserved1 + k >= dst->nindirectsyms) break;   // a malformed table ends the section
                if (idx[k] == INDIRECT_SYMBOL_ABS || idx[k] == INDIRECT_SYMBOL_LOCAL || (idx[k] & INDIRECT_SYMBOL_ABS) || idx[k] >= st->nsyms) continue;
                if (syms[idx[k]].n_un.n_strx >= st->strsize) continue;
                const char *name = strs + syms[idx[k]].n_un.n_strx;
                void *repl = NULL, *orig = NULL;
                if (!strcmp(name, "_VTCompressionSessionCreate")) { repl = (void *)nvmtl_vt_create_hook; orig = (void *)g_vt_create_orig; }
                else if (!strcmp(name, "_VTCopySupportedPropertyDictionaryForEncoder")) { repl = (void *)nvmtl_vt_props_hook; orig = (void *)g_vt_props_orig; }
                else if (g_rc_enabled && !strcmp(name, "_VTSessionSetProperty")) { repl = (void *)nvmtl_vt_setprop_hook; orig = (void *)g_vt_setprop_orig; }
                if (!repl || slots[k] == repl) continue;
                if (slots[k] != orig) continue;   // someone else's pointer (another hook): not ours to replace
                vm_address_t page = (vm_address_t)&slots[k] & ~(vm_address_t)(vm_page_size - 1);
                // a page that cannot be made writable (hardened runtime, shared cache) is skipped: writing anyway would fault
                if (vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) continue;
                slots[k] = repl;
                if (is_const) vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);   // __DATA_CONST goes back to read-only
            }
        }
    }
}

// Called once the encoder is registered in this process.
static void nvmtl_vt_spec_hook_install(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("NVMTL_NO_VT_SPEC_HOOK")) return;
        g_vt_create_orig = (nvmtl_vt_create_fn)dlsym(RTLD_DEFAULT, "VTCompressionSessionCreate");
        g_vt_props_orig = (nvmtl_vt_props_fn)dlsym(RTLD_DEFAULT, "VTCopySupportedPropertyDictionaryForEncoder");
        if (!g_vt_create_orig || !g_vt_props_orig) { nvlog("nvenc: VideoToolbox symbols not found - low-latency hook off"); return; }
        {   // NVMTL_VT_RC is read here, once: the plugin clears NVMTL_* variables later
            const char *rc = getenv("NVMTL_VT_RC");
            g_vt_setprop_orig = (nvmtl_vt_setprop_fn)dlsym(RTLD_DEFAULT, "VTSessionSetProperty");
            g_vt_copyprop = (nvmtl_vt_copyprop_fn)dlsym(RTLD_DEFAULT, "VTSessionCopyProperty");
            g_cm_size = (nvmtl_cm_size_fn)dlsym(RTLD_DEFAULT, "CMSampleBufferGetTotalSampleSize");
            g_cm_att = (nvmtl_cm_att_fn)dlsym(RTLD_DEFAULT, "CMSampleBufferGetSampleAttachmentsArray");
            g_rc_enabled = rc && rc[0] == '1' && g_vt_setprop_orig && g_vt_copyprop && g_cm_size && g_cm_att;
            if (rc && rc[0] == '1' && !g_rc_enabled) nvlog("nvenc: NVMTL_VT_RC=1 but a VideoToolbox or CoreMedia symbol is missing - bitrate control off");
            else if (g_rc_enabled) nvlog("nvenc: bitrate control enabled in %s", getprogname());
        }
        _dyld_register_func_for_add_image(nvmtl_vt_rebind_image);   // also runs for every image already loaded
    });
}
