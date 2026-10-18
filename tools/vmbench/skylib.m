// skylib: load the system's SkyLight compositor metallib through this device and list its function names.
// usage: skylib
// build: clang -fobjc-arc -O2 -Wall -o skylib skylib.m -framework Foundation -framework Metal
// exit: 0 names printed; 2 newLibraryWithURL failed
// output: the function count, how many names contain "mip", then every name.
//   Names only: the bitcode is not printed.
// permission: none. Reads a system framework resource that is already on the machine.
// cannot show: which of those functions WindowServer ran, or whether a name with
//   no AIR behind it can build a pipeline (that is skymip, for the mip kernels).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); printf("device %s\n", dev.name.UTF8String);
    NSURL *u = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/SkyLightShaders.air64.metallib"];
    NSError *e = nil; id<MTLLibrary> lib = [dev newLibraryWithURL:u error:&e]; if (!lib) { printf("load failed: %s\n", e.localizedDescription.UTF8String); return 2; }
    NSArray *names = [lib.functionNames sortedArrayUsingSelector:@selector(compare:)]; printf("functionNames: %lu\n", (unsigned long)names.count);
    int mip = 0; for (NSString *n in names) { if ([n.lowercaseString containsString:@"mip"]) mip++; }
    printf("names containing 'mip': %d\n", mip); for (NSString *n in names) printf("  %s\n", n.UTF8String);
    return 0; } }
