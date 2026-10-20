// Hardware H.264/HEVC stress probe. The current VT hook is installed in this process only;
// no installed driver is replaced. Rates use nominal video time, not execution speed.
// Decode every frame in software, regenerate its source, and report PSNR without imposing
// a high-quality threshold on deliberately starved bitrate tests. Memory is bounded by a
// 30-frame compressed batch. Decode/source generation are excluded from encode timings.
// Usage: NVMTL_VT_RC=0|1 nvenc_matrix h264|hevc W H N FPS BPS static|motion|noise|cuts|edges SESSIONS LABEL OUTPUT.json
// TEST_TARGET2 optionally changes bitrate halfway through each session; TEST_DUMP writes Annex B (one session).
// TEST_PACE=1 paces 30-frame batches to nominal video time for bounded-duration soak tests.
// TEST_GOP overrides the default one-second keyframe interval (in frames).
// Build: clang -fobjc-arc -O1 tools/nvenc_matrix.m -o nvenc_matrix -framework Foundation \
//   -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Metal
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Metal/Metal.h>
#include <math.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>
#define nvlog(...) do {} while (0)
#include "../plugin/nvmtl_vt_spec_hook.h"

static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static double cpu_ms(void) { struct rusage r; getrusage(RUSAGE_SELF,&r); return r.ru_utime.tv_sec*1000.0+r.ru_utime.tv_usec/1000.0+r.ru_stime.tv_sec*1000.0+r.ru_stime.tv_usec/1000.0; }
static uint32_t hash32(uint32_t x) { x ^= x>>16; x *= 0x7feb352du; x ^= x>>15; x *= 0x846ca68bu; return x^(x>>16); }
static CVPixelBufferRef frame(int w,int h,int i,int fps,const char *pattern) {
    CVPixelBufferRef p=NULL;
    if(CVPixelBufferCreate(NULL,w,h,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&p)) return NULL;
    if(CVPixelBufferLockBaseAddress(p,0)) { CFRelease(p); return NULL; }
    int type=!strcmp(pattern,"static")?0:!strcmp(pattern,"noise")?2:!strcmp(pattern,"edges")?4:1;
    if(!strcmp(pattern,"cuts")) type=(i/(fps*2))%4;
    int t=type==0?0:i;
    uint8_t *y=CVPixelBufferGetBaseAddressOfPlane(p,0),*c=CVPixelBufferGetBaseAddressOfPlane(p,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(p,0),cs=CVPixelBufferGetBytesPerRowOfPlane(p,1);
    for(int row=0;row<h;row++) for(int x=0;x<w;x++) {
        uint32_t v=hash32((uint32_t)(x+2*t)*2654435761u^(uint32_t)row*40503u^(type==2?(uint32_t)i*2246822519u:0));
        int z=type==2?16+(v%220):type==3?100:type==4?(((x+t)%128<2 || row%32<2 || (((x+t)/7+row/13)&7)==0)?220:32):
            40+(((x+4*t)%w)*150)/w+30*((((x+2*t)/32)+(row/32))&1)+(int)(v&15);
        y[row*ys+x]=(uint8_t)(z>235?235:z);
    }
    for(int row=0;row<h/2;row++) for(int x=0;x<w/2;x++) {
        c[row*cs+2*x]=(uint8_t)(108+(x*40)/(w/2));
        c[row*cs+2*x+1]=(uint8_t)(108+(row*40)/(h/2));
    }
    CVPixelBufferUnlockBaseAddress(p,0); return p;
}
static double plane_psnr(CVPixelBufferRef a,CVPixelBufferRef b,int plane,int width) {
    const uint8_t *x=CVPixelBufferGetBaseAddressOfPlane(a,plane),*y=CVPixelBufferGetBaseAddressOfPlane(b,plane);
    size_t xs=CVPixelBufferGetBytesPerRowOfPlane(a,plane),ys=CVPixelBufferGetBytesPerRowOfPlane(b,plane),rows=CVPixelBufferGetHeightOfPlane(a,plane);
    double se=0; for(size_t r=0;r<rows;r++) for(int k=0;k<width;k++) { int d=x[r*xs+k]-y[r*ys+k]; se+=(double)d*d; }
    return se?10*log10(255.0*255.0/(se/(rows*width))):99;
}
typedef struct {
    NSMutableArray *samples,*lat,*sizes,*seconds;
    NSMutableIndexSet *seen;
    CMVideoCodecType codec;
    VTCompressionSessionRef session;
    int w,h,n,fps,encoded,enc_errors,dec_errors,decoded,qp_min,qp_max,idr_count;
    double idr_bytes,p_bytes;
    const char *pattern;
    double *submitted;
    double sum_y,sum_uv,min_y,steady_y;
    int min_frame,steady_count;
} context;
static void output(void *ref,void *src,OSStatus st,VTEncodeInfoFlags f,CMSampleBufferRef sample) {
    context *c=ref; intptr_t i=(intptr_t)src-1;
    @synchronized(c->samples) {
        if(st || !sample || i<0 || i>=c->n) { c->enc_errors++; return; }
        CMFormatDescriptionRef fd=CMSampleBufferGetFormatDescription(sample);
        if(!fd || CMFormatDescriptionGetMediaSubType(fd)!=c->codec) { c->enc_errors++; return; }
        [c->lat addObject:@(now_ms()-c->submitted[i])];
        size_t size=CMSampleBufferGetTotalSampleSize(sample);
        CFArrayRef att=CMSampleBufferGetSampleAttachmentsArray(sample,false);
        CFDictionaryRef first=att && CFArrayGetCount(att)?CFArrayGetValueAtIndex(att,0):NULL;
        bool key=!(first && CFDictionaryContainsKey(first,kCMSampleAttachmentKey_NotSync) && CFBooleanGetValue(CFDictionaryGetValue(first,kCMSampleAttachmentKey_NotSync)));
        if(key){c->idr_count++;c->idr_bytes+=size;}else c->p_bytes+=size;
        [c->sizes addObject:@(size)];
        NSUInteger sec=(NSUInteger)i/c->fps;
        c->seconds[sec]=@([c->seconds[sec] doubleValue]+size*8.0/1e6);
        [c->samples addObject:(__bridge id)sample]; c->encoded++;
        pthread_mutex_lock(&g_rcs_lock);
        for(int k=0;k<NVMTL_VT_RC_SESSIONS;k++) if(g_rcs[k] && g_rcs[k]->active && g_rcs[k]->session==c->session && g_rcs[k]->started) {
            int q=g_rcs[k]->last_qp; c->qp_min=MIN(c->qp_min,q); c->qp_max=MAX(c->qp_max,q);
        }
        pthread_mutex_unlock(&g_rcs_lock);
    }
}
static bool dump_sample(FILE *out,CMSampleBufferRef sample,bool hevc) {
    if(!out) return true;
    CMVideoFormatDescriptionRef fd=CMSampleBufferGetFormatDescription(sample);
    CFArrayRef att=CMSampleBufferGetSampleAttachmentsArray(sample,false);
    CFDictionaryRef d=att && CFArrayGetCount(att)?CFArrayGetValueAtIndex(att,0):NULL;
    bool key=!(d && CFDictionaryContainsKey(d,kCMSampleAttachmentKey_NotSync) && CFBooleanGetValue(CFDictionaryGetValue(d,kCMSampleAttachmentKey_NotSync)));
    static const uint8_t sc[4]={0,0,0,1};
    size_t count=0,sz=0; int nlen=4; const uint8_t *ps=NULL;
    OSStatus st=hevc?CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd,0,&ps,&sz,&count,&nlen):CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd,0,&ps,&sz,&count,&nlen);
    if(st || nlen<1 || nlen>4) return false;
    for(size_t k=0;key && k<count;k++) {
        st=hevc?CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd,k,&ps,&sz,NULL,NULL):CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd,k,&ps,&sz,NULL,NULL);
        if(st || fwrite(sc,1,4,out)!=4 || fwrite(ps,1,sz,out)!=sz) return false;
    }
    CMBlockBufferRef bb=CMSampleBufferGetDataBuffer(sample); if(!bb) return false;
    size_t size=CMBlockBufferGetDataLength(bb),pos=0;
    NSMutableData *data=[NSMutableData dataWithLength:size];
    if(CMBlockBufferCopyDataBytes(bb,0,size,data.mutableBytes)) return false;
    const uint8_t *b=data.bytes;
    while(pos+(size_t)nlen<=size) {
        uint32_t n=0; for(int j=0;j<nlen;j++) n=(n<<8)|b[pos++];
        if(!n || n>size-pos || fwrite(sc,1,4,out)!=4 || fwrite(b+pos,1,n,out)!=n) return false;
        pos+=n;
    }
    return pos==size;
}
static void decode_batch(context *c,VTDecompressionSessionRef ds,FILE *dump) {
    for(id obj in c->samples) {
        CMSampleBufferRef sample=(__bridge CMSampleBufferRef)obj;
        if(!dump_sample(dump,sample,c->codec==kCMVideoCodecType_HEVC)) c->enc_errors++;
        OSStatus st=VTDecompressionSessionDecodeFrameWithOutputHandler(ds,sample,0,NULL,^(OSStatus status,VTDecodeInfoFlags flags,CVImageBufferRef img,CMTime pts,CMTime dur) {
            @synchronized(c->seen) {
                if(!CMTIME_IS_NUMERIC(pts)){c->dec_errors++;return;}
                int i=(int)llround(CMTimeGetSeconds(pts)*c->fps);
                if(status || !img || i<0 || i>=c->n || [c->seen containsIndex:i] ||
                   CVPixelBufferGetWidth(img)!=(size_t)c->w || CVPixelBufferGetHeight(img)!=(size_t)c->h ||
                   CVPixelBufferGetPixelFormatType(img)!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { c->dec_errors++; return; }
                CVPixelBufferRef src=frame(c->w,c->h,i,c->fps,c->pattern);
                if(!src) { c->dec_errors++; return; }
                CVReturn la=CVPixelBufferLockBaseAddress(src,kCVPixelBufferLock_ReadOnly),lb=CVPixelBufferLockBaseAddress(img,kCVPixelBufferLock_ReadOnly);
                if(la || lb) c->dec_errors++;
                else {
                    double y=plane_psnr(src,img,0,c->w),uv=plane_psnr(src,img,1,c->w);
                    c->sum_y+=y; c->sum_uv+=uv;
                    if(y<c->min_y) { c->min_y=y; c->min_frame=i; }
                    if(i>=c->fps) { c->steady_y+=y; c->steady_count++; }
                    [c->seen addIndex:i]; c->decoded++;
                }
                if(!la) CVPixelBufferUnlockBaseAddress(src,kCVPixelBufferLock_ReadOnly);
                if(!lb) CVPixelBufferUnlockBaseAddress(img,kCVPixelBufferLock_ReadOnly);
                CFRelease(src);
            }
        });
        if(st) c->dec_errors++;
    }
    VTDecompressionSessionWaitForAsynchronousFrames(ds);
    [c->samples removeAllObjects];
}
static double percentile(NSArray *a,double p) { if(!a.count)return 0; NSArray *s=[a sortedArrayUsingSelector:@selector(compare:)]; return [s[MIN((NSUInteger)(p*s.count),s.count-1)] doubleValue]; }
static NSDictionary *run(CMVideoCodecType codec,int w,int h,int n,int fps,double target,const char *pattern) {
    context c={0}; c.samples=[NSMutableArray array]; c.lat=[NSMutableArray array]; c.sizes=[NSMutableArray array]; c.seconds=[NSMutableArray array]; c.seen=[NSMutableIndexSet indexSet];
    c.codec=codec;c.w=w;c.h=h;c.n=n;c.fps=fps;c.pattern=pattern;c.min_y=99;c.min_frame=-1;c.qp_min=99;c.qp_max=-1;
    for(int k=0;k<(n+fps-1)/fps;k++)[c.seconds addObject:@0];
    c.submitted=calloc((size_t)n,sizeof(double)); if(!c.submitted) return @{@"correct":@NO,@"error":@"allocation"};
    VTCompressionSessionRef cs=NULL; VTDecompressionSessionRef ds=NULL;
    double create_start=now_ms();
    NSDictionary *spec=@{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES,@"EnableLowLatencyRateControl":@YES};
    OSStatus st=VTCompressionSessionCreate(NULL,w,h,codec,(__bridge CFDictionaryRef)spec,NULL,NULL,output,&c,&cs);
    double create_ms=now_ms()-create_start;
    if(st || !cs) {
        fprintf(stderr,"VTCompressionSessionCreate %dx%d: OSStatus %d (session=%p)\n",w,h,(int)st,(void *)cs);
        free(c.submitted); if(cs)CFRelease(cs); return @{@"correct":@NO,@"create_status":@(st),@"create_ms":@(create_ms)};
    }
    c.session=cs;
    CFTypeRef hw=NULL; VTSessionCopyProperty(cs,kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,NULL,&hw);
    bool hardware=hw && CFGetTypeID(hw)==CFBooleanGetTypeID() && CFBooleanGetValue(hw); if(hw)CFRelease(hw);
    int prop_errors=0;
    prop_errors+=VTSessionSetProperty(cs,kVTCompressionPropertyKey_RealTime,kCFBooleanTrue)!=0;
    prop_errors+=VTSessionSetProperty(cs,kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse)!=0;
    prop_errors+=VTSessionSetProperty(cs,kVTCompressionPropertyKey_ExpectedFrameRate,(__bridge CFTypeRef)@(fps))!=0;
    int gop=getenv("TEST_GOP")?atoi(getenv("TEST_GOP")):fps;
    prop_errors+=VTSessionSetProperty(cs,kVTCompressionPropertyKey_MaxKeyFrameInterval,(__bridge CFTypeRef)@(MAX(1,gop)))!=0;
    if(target>0)prop_errors+=VTSessionSetProperty(cs,kVTCompressionPropertyKey_AverageBitRate,(__bridge CFTypeRef)@(target))!=0;
    CFDictionaryRef props=NULL; OSStatus props_st=VTCopySupportedPropertyDictionaryForEncoder(w,h,codec,(__bridge CFDictionaryRef)spec,NULL,&props);
    if(props)CFRelease(props);
    st=VTCompressionSessionPrepareToEncodeFrames(cs);
    if(st) {
        fprintf(stderr,"VTCompressionSessionPrepareToEncodeFrames (StartSession) %dx%d: OSStatus %d\n",w,h,(int)st);
        VTCompressionSessionInvalidate(cs);CFRelease(cs);free(c.submitted);
        return @{@"correct":@NO,@"prepare_status":@(st),@"create_ms":@(create_ms)};
    }
    const char *dump_path=getenv("TEST_DUMP"); FILE *dump=dump_path?fopen(dump_path,"wb"):NULL;
    if(dump_path && !dump)c.enc_errors++;
    double wall_ms=0,encode_cpu=0,total_start=now_ms(); bool decoder_hardware=false;
    for(int i=0;i<n;i++) { @autoreleasepool {
        if(getenv("TEST_TARGET2") && i==n/2) prop_errors+=VTSessionSetProperty(cs,kVTCompressionPropertyKey_AverageBitRate,(__bridge CFTypeRef)@(atof(getenv("TEST_TARGET2"))))!=0;
        CVPixelBufferRef pb=frame(w,h,i,fps,pattern);
        if(!pb) { c.enc_errors++; break; }
        double cpu=cpu_ms(),t=now_ms(); c.submitted[i]=t;
        st=VTCompressionSessionEncodeFrame(cs,pb,CMTimeMake(i,fps),CMTimeMake(1,fps),NULL,(void *)(intptr_t)(i+1),NULL);
        wall_ms+=now_ms()-t; encode_cpu+=cpu_ms()-cpu; CFRelease(pb);
        if(st) {
            fprintf(stderr,"VTCompressionSessionEncodeFrame (StartSession/encode) %dx%d frame %d: OSStatus %d\n",w,h,i,(int)st);
            c.enc_errors++;
            break;
        }
        if((i+1)%30==0 || i==n-1) {
            cpu=cpu_ms();t=now_ms(); st=VTCompressionSessionCompleteFrames(cs,kCMTimeInvalid);
            wall_ms+=now_ms()-t;encode_cpu+=cpu_ms()-cpu;
            if(st) { fprintf(stderr,"VTCompressionSessionCompleteFrames: OSStatus %d\n",(int)st);c.enc_errors++; }
            if(!ds && c.samples.count) {
                CMFormatDescriptionRef fd=CMSampleBufferGetFormatDescription((__bridge CMSampleBufferRef)c.samples[0]);
                st=VTDecompressionSessionCreate(NULL,fd,(__bridge CFDictionaryRef)@{(id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder:@NO},(__bridge CFDictionaryRef)@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)},NULL,&ds);
                if(st || !ds) { c.dec_errors++; break; }
                CFTypeRef dh=NULL;VTSessionCopyProperty(ds,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,NULL,&dh);
                decoder_hardware=dh && CFGetTypeID(dh)==CFBooleanGetTypeID() && CFBooleanGetValue(dh);if(dh)CFRelease(dh);
            }
            if(ds)decode_batch(&c,ds,dump);
            if(getenv("TEST_PACE") && !strcmp(getenv("TEST_PACE"),"1")) {
                double remaining=(i+1)*1000.0/fps-(now_ms()-total_start);
                if(remaining>0)usleep((useconds_t)(remaining*1000.0));
            }
            if((i+1)%600==0){printf("PROGRESS %d/%d decoded=%d\n",i+1,n,c.decoded);fflush(stdout);}
        }
    } }
    double total_ms=now_ms()-total_start;
    VTCompressionSessionInvalidate(cs);CFRelease(cs);
    if(ds){VTDecompressionSessionInvalidate(ds);CFRelease(ds);} if(dump && fclose(dump))c.enc_errors++;
    double steady=0;int seconds=0; for(NSUInteger k=1;k<c.seconds.count;k++) if((k+1)*fps<=(NSUInteger)n) {steady+=[c.seconds[k] doubleValue];seconds++;}
    double mbps=seconds?steady/seconds:0;
    bool ok=hardware && !decoder_hardware && c.encoded==n && c.decoded==n && !c.enc_errors && !c.dec_errors && !prop_errors && props_st==0;
    NSDictionary *result=@{@"correct":@(ok),@"hardware_encoder":@(hardware),@"hardware_decoder":@(decoder_hardware),@"encoded":@(c.encoded),@"decoded":@(c.decoded),@"encoder_errors":@(c.enc_errors),@"decoder_errors":@(c.dec_errors),@"property_errors":@(prop_errors),@"props_status":@(props_st),@"create_ms":@(create_ms),@"gop_frames":@(gop),@"idr_count":@(c.idr_count),@"idr_total_bytes":@(c.idr_bytes),@"p_total_bytes":@(c.p_bytes),@"encode_service_fps":@(wall_ms?n*1000.0/wall_ms:0),@"encode_cpu_ms_frame":@(encode_cpu/n),@"latency_p50_ms":@(percentile(c.lat,.5)),@"latency_p95_ms":@(percentile(c.lat,.95)),@"latency_max_ms":@(percentile(c.lat,1)),@"frames_over_budget":@([[c.lat filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF > %f",1000.0/fps]] count]),@"mean_y_psnr":@(c.decoded?c.sum_y/c.decoded:0),@"min_y_psnr":@(c.min_y),@"min_y_frame":@(c.min_frame),@"mean_uv_psnr":@(c.decoded?c.sum_uv/c.decoded:0),@"steady_y_psnr":@(c.steady_count?c.steady_y/c.steady_count:0),@"steady_mbps":@(mbps),@"per_second_mbps":c.seconds,@"rate_within_25pct":target>0?@(fabs(mbps*1e6-target)<=target*.25):(id)[NSNull null],@"next_qp_min":@(c.qp_max<0?-1:c.qp_min),@"next_qp_max":@(c.qp_max),@"total_wall_ms":@(total_ms)};
    free(c.submitted); return result;
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=11){fprintf(stderr,"usage: codec W H N FPS BPS pattern sessions label output.json\n");return 64;}
    CMVideoCodecType codec=!strcmp(argv[1],"hevc")?kCMVideoCodecType_HEVC:kCMVideoCodecType_H264;
    int w=atoi(argv[2]),h=atoi(argv[3]),n=atoi(argv[4]),fps=atoi(argv[5]),sessions=atoi(argv[8]);double target=atof(argv[6]);
    // argv[9] is a reserved run label, written to metadata so command/log/result association is explicit.
    if((strcmp(argv[1],"hevc") && strcmp(argv[1],"h264")) || w<64 || h<64 || w>4096 || h>2160 || (w&1) || (h&1) || fps<1 || fps>240 || n<fps*2 || n>60000 || sessions<1 || sessions>100 || !isfinite(target) || target<0 || (strcmp(argv[7],"static") && strcmp(argv[7],"motion") && strcmp(argv[7],"noise") && strcmp(argv[7],"cuts") && strcmp(argv[7],"edges")))return 64;
    nvmtl_vt_spec_hook_install(); id<MTLDevice> device=MTLCreateSystemDefaultDevice(); usleep(300000);
    NSMutableArray *results=[NSMutableArray array]; int fails=0;
    for(int k=0;k<sessions;k++) {
        NSDictionary *r=run(codec,w,h,n,fps,target,argv[7]); [results addObject:r];fails+=![r[@"correct"] boolValue];
        NSDictionary *doc=@{@"codec":@(argv[1]),@"width":@(w),@"height":@(h),@"frames":@(n),@"fps":@(fps),@"target_bps":@(target),@"paced_batches":@(getenv("TEST_PACE") && !strcmp(getenv("TEST_PACE"),"1")),@"target2_bps":getenv("TEST_TARGET2")?@(atof(getenv("TEST_TARGET2"))):(id)[NSNull null],@"pattern":@(argv[7]),@"label":@(argv[9]),@"rc_enabled":@(g_rc_enabled),@"device":device.name?:@"none",@"sessions":results};
        NSError *err=nil;NSData *json=[NSJSONSerialization dataWithJSONObject:doc options:NSJSONWritingPrettyPrinted error:&err];
        if(!json || ![json writeToFile:@(argv[10]) options:NSDataWritingAtomic error:&err]){fprintf(stderr,"result write failed: %s\n",err.description.UTF8String);return 74;}
        printf("SESSION %d correct=%d encoded=%d decoded=%d rate=%.3f Mbps PSNR=%.2f min=%.2f p95=%.2f ms\n",k+1,[r[@"correct"] boolValue],[r[@"encoded"] intValue],[r[@"decoded"] intValue],[r[@"steady_mbps"] doubleValue],[r[@"mean_y_psnr"] doubleValue],[r[@"min_y_psnr"] doubleValue],[r[@"latency_p95_ms"] doubleValue]);fflush(stdout);
    }
    return fails?1:0;
} }
