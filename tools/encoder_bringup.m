// Build: clang -arch x86_64 -fobjc-arc tools/encoder_bringup.m -o encoder_bringup -framework Foundation -framework Metal -framework VideoToolbox -framework CoreMedia -framework CoreVideo
// Run: NVENC_VT_VERBOSE=1 ./encoder_bringup h264|hevc; exit 0 pass, 1 fail.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#define nvlog(...) do {} while (0)
#include "../plugin/nvmtl_vt_spec_hook.h"
static int encoded,callback_error;
static void output(void *ref,void *src,OSStatus status,VTEncodeInfoFlags flags,CMSampleBufferRef sample) {
    if(status || !sample) callback_error=1; else encoded++;
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2 || (strcmp(argv[1],"h264") && strcmp(argv[1],"hevc")))return 1;
    nvmtl_vt_spec_hook_install();id<MTLDevice> device=MTLCreateSystemDefaultDevice();usleep(300000);
    if(!device) { fprintf(stderr,"No Metal device\n");return 1; }
    VTCompressionSessionRef session=NULL;CVPixelBufferRef pixel=NULL;
    CMVideoCodecType codec=!strcmp(argv[1],"hevc")?kCMVideoCodecType_HEVC:kCMVideoCodecType_H264;
    NSDictionary *spec=@{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES};
    OSStatus st=VTCompressionSessionCreate(NULL,1920,1080,codec,(__bridge CFDictionaryRef)spec,NULL,NULL,output,NULL,&session);
    if(st || !session) { fprintf(stderr,"VTCompressionSessionCreate: OSStatus %d\n",(int)st);if(session)CFRelease(session);return 1; }
    CFTypeRef hw=NULL;OSStatus hwst=VTSessionCopyProperty(session,kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,NULL,&hw);
    bool hardware=!hwst && hw && CFGetTypeID(hw)==CFBooleanGetTypeID() && CFBooleanGetValue(hw);if(hw)CFRelease(hw);
    st=VTCompressionSessionPrepareToEncodeFrames(session);
    if(st)fprintf(stderr,"VTCompressionSessionPrepareToEncodeFrames (StartSession): OSStatus %d\n",(int)st);
    if(!st)st=CVPixelBufferCreate(NULL,1920,1080,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&pixel);
    if(!st && pixel) {
        st=CVPixelBufferLockBaseAddress(pixel,0);
        if(!st) {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel,0),16,CVPixelBufferGetBytesPerRowOfPlane(pixel,0)*1080);
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel,1),128,CVPixelBufferGetBytesPerRowOfPlane(pixel,1)*540);
            CVPixelBufferUnlockBaseAddress(pixel,0);
            st=VTCompressionSessionEncodeFrame(session,pixel,CMTimeMake(0,60),CMTimeMake(1,60),NULL,NULL,NULL);
            if(st)fprintf(stderr,"VTCompressionSessionEncodeFrame (StartSession): OSStatus %d\n",(int)st);
        }
    }
    OSStatus complete=VTCompressionSessionCompleteFrames(session,kCMTimeInvalid);
    if(st || complete)fprintf(stderr,"encoder bring-up: OSStatus %d, CompleteFrames %d\n",(int)st,(int)complete);
    VTCompressionSessionInvalidate(session);CFRelease(session);if(pixel)CFRelease(pixel);
    bool ok=!st && !complete && hardware && encoded==1 && !callback_error;
    printf("%s: %s 1920x1080 hardware=%d encoded=%d\n",ok?"PASS":"FAIL",argv[1],hardware,encoded);return ok?0:1;
} }
