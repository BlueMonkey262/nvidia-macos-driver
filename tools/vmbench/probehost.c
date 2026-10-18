// probehost: a fixed host for capture experiments. macOS ties the Screen Recording grant to this binary's signature, so
// the experiment itself is a dylib it loads: rebuild the dylib freely, grant the host once.
// usage: open -W -a out/capture-host.app --stdout FILE --args [arguments for probe_main]
//   loads the dylib named by $PROBE_DYLIB, or probe.dylib in the directory that holds the .app bundle, and calls
//   int probe_main(int argc, char **argv) in it (tearscan.m builds as one: see build_all.sh). exit: 3 the dylib did not
//   load, 4 it has no probe_main, otherwise probe_main's own exit code.
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    char path[PATH_MAX], exe[PATH_MAX], real[PATH_MAX];
    uint32_t n = sizeof exe;
    const char *e = getenv("PROBE_DYLIB");
    if (!e) {
        // <dir>/capture-host.app/Contents/MacOS/capture-host -> <dir>/probe.dylib
        if (_NSGetExecutablePath(exe, &n) || !realpath(exe, real)) { fprintf(stderr, "cannot find own path\n"); return 3; }
        char *d = dirname(real);                       // .../Contents/MacOS
        snprintf(path, sizeof path, "%s/../../../probe.dylib", d);
        e = path;
    }
    void *h = dlopen(e, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 3; }
    int (*m)(int, char **) = dlsym(h, "probe_main");
    if (!m) { fprintf(stderr, "no probe_main in %s\n", e); return 4; }
    return m(argc, argv);
}
