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
// NVMTL_NO_VT_SPEC_HOOK=1 turns it off.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

typedef int32_t (*nvmtl_vt_create_fn)(CFAllocatorRef, int32_t, int32_t, uint32_t, CFDictionaryRef, CFDictionaryRef,
                                      CFAllocatorRef, void *, void *, void *);
typedef int32_t (*nvmtl_vt_props_fn)(int32_t, int32_t, uint32_t, CFDictionaryRef, CFStringRef *, CFDictionaryRef *);
static nvmtl_vt_create_fn g_vt_create_orig;
static nvmtl_vt_props_fn g_vt_props_orig;

// A retained copy of spec without the low-latency key (or spec itself, retained, when it has none).
static CFDictionaryRef nvmtl_vt_spec_without_lowlatency(uint32_t codec, CFDictionaryRef spec)
{
    if (!spec) return NULL;
    if (codec != 'avc1' || !CFDictionaryContainsKey(spec, CFSTR("EnableLowLatencyRateControl"))) return CFRetain(spec);
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, spec);
    if (!m) return CFRetain(spec);   // out of memory: pass the original on rather than crash
    CFDictionaryRemoveValue(m, CFSTR("EnableLowLatencyRateControl"));
    nvlog("nvenc: dropped EnableLowLatencyRateControl from an H.264 specification in %s", getprogname());
    return m;
}
// The supported-property dictionaries of our encoder, one per frame size (what the encoder reports can depend on it).
enum { NVMTL_VT_CACHE_ENTRIES = 8 };
static pthread_mutex_t g_vt_cache_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_vt_prime_lock = PTHREAD_MUTEX_INITIALIZER;   // one priming lookup at a time (the engine is one per process)
static struct { int32_t w, h; CFStringRef id; CFDictionaryRef props; } g_vt_cache[NVMTL_VT_CACHE_ENTRIES];
static unsigned g_vt_cache_next;
enum { NVMTL_VT_COULD_NOT_FIND_ENCODER = -12908 };

// The index of the entry for this size, or -1. Call with g_vt_cache_lock held.
static int nvmtl_vt_cache_find(int32_t w, int32_t h)
{
    for (int i = 0; i < NVMTL_VT_CACHE_ENTRIES; i++) if (g_vt_cache[i].props && g_vt_cache[i].w == w && g_vt_cache[i].h == h) return i;
    return -1;
}
// Keep the answer when it came from our encoder; a later answer for the same size replaces the earlier one.
static void nvmtl_vt_cache_store(int32_t w, int32_t h, CFStringRef encoderID, CFDictionaryRef props)
{
    if (!encoderID || !props || CFStringCompare(encoderID, CFSTR("com.nvmtl.videoencoder.avc.nvenc"), 0) != kCFCompareEqualTo) return;
    CFRetain(encoderID); CFRetain(props);
    pthread_mutex_lock(&g_vt_cache_lock);
    int i = nvmtl_vt_cache_find(w, h);
    if (i < 0) i = (int)(g_vt_cache_next++ % NVMTL_VT_CACHE_ENTRIES);
    CFStringRef old_id = g_vt_cache[i].id; CFDictionaryRef old_props = g_vt_cache[i].props;
    g_vt_cache[i].w = w; g_vt_cache[i].h = h; g_vt_cache[i].id = encoderID; g_vt_cache[i].props = props;
    pthread_mutex_unlock(&g_vt_cache_lock);
    if (old_id) CFRelease(old_id);
    if (old_props) CFRelease(old_props);
}
// One lookup for each frame size, made right before a hardware H.264 session of that size is created (no session open yet).
static void nvmtl_vt_cache_prime(int32_t w, int32_t h, uint32_t codec, CFDictionaryRef spec)
{
    if (codec != 'avc1' || !spec || !g_vt_props_orig) return;
    pthread_mutex_lock(&g_vt_prime_lock);   // two creates at once do not both ask the encoder
    pthread_mutex_lock(&g_vt_cache_lock);
    const bool have = nvmtl_vt_cache_find(w, h) >= 0;
    pthread_mutex_unlock(&g_vt_cache_lock);
    if (!have) {
        CFStringRef id = NULL; CFDictionaryRef props = NULL;
        int32_t pr = g_vt_props_orig(w, h, codec, spec, &id, &props);
        nvlog("nvenc: primed the supported-property cache in %s: %dx%d -> %d", getprogname(), (int)w, (int)h, (int)pr);
        if (pr == 0) nvmtl_vt_cache_store(w, h, id, props);
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
    int32_t r = g_vt_create_orig(a, w, h, codec, s, attrs, ca, cb, refcon, out);
    if (codec == 'avc1') nvlog("nvenc: VTCompressionSessionCreate %dx%d in %s -> %d", (int)w, (int)h, getprogname(), (int)r);
    if (s) CFRelease(s);
    return r;
}
static int32_t nvmtl_vt_props_hook(int32_t w, int32_t h, uint32_t codec, CFDictionaryRef spec, CFStringRef *idOut,
                                   CFDictionaryRef *propsOut)
{
    CFDictionaryRef s = nvmtl_vt_spec_without_lowlatency(codec, spec);
    int32_t r = g_vt_props_orig(w, h, codec, s, idOut, propsOut);
    if (s) CFRelease(s);
    if (codec == 'avc1') nvlog("nvenc: VTCopySupportedPropertyDictionaryForEncoder %dx%d in %s -> %d", (int)w, (int)h, getprogname(), (int)r);
    if (r == 0) { if (codec == 'avc1' && idOut && *idOut && propsOut && *propsOut) nvmtl_vt_cache_store(w, h, *idOut, *propsOut); return r; }
    if (r == NVMTL_VT_COULD_NOT_FIND_ENCODER && codec == 'avc1' && propsOut) {   // ffmpeg passes no encoder-ID output
        // answered only from an entry for this very size: a different size keeps its error
        pthread_mutex_lock(&g_vt_cache_lock);
        const int i = nvmtl_vt_cache_find(w, h);
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
        _dyld_register_func_for_add_image(nvmtl_vt_rebind_image);   // also runs for every image already loaded
    });
}
