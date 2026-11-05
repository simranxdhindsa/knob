#include "driver.h"
#include "loopback.h"
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE==2 && ATOMIC_INT_LOCK_FREE==2,"Realtime atomics must be lock-free");
_Atomic UInt32 kn_running=0, kn_gain_bits=0x3f800000, kn_muted=0, kn_input_active=1, kn_output_active=1;
_Atomic UInt64 kn_anchor=0, kn_epoch=1;
double kn_ticks_per_frame=0;
typedef struct { _Atomic UInt64 stamp, epoch; _Atomic UInt32 left,right; } KnFrame;
static KnFrame ring[KN_CAPACITY];
static pthread_mutex_t lifecycle=PTHREAD_MUTEX_INITIALIZER;
static UInt32 clients[64];
static _Atomic UInt64 clock_sequence=0;

OSStatus kn_start(AudioServerPlugInDriverRef d,AudioObjectID o,UInt32 c) {
    if(d!=kn_driver || o!=KN_DEVICE) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&lifecycle);
    UInt32 count=atomic_load(&kn_running),slot=64;
    for(UInt32 i=0;i<count;i++) if(clients[i]==c) { pthread_mutex_unlock(&lifecycle); return kAudioHardwareIllegalOperationError; }
    if(count<64) slot=count;
    if(slot==64) { pthread_mutex_unlock(&lifecycle); return kAudioHardwareIllegalOperationError; }
    if(count==0) {
        atomic_fetch_add(&clock_sequence,1);
        atomic_fetch_add(&kn_epoch,1); atomic_store(&kn_anchor,mach_absolute_time());
        atomic_fetch_add(&clock_sequence,1);
    }
    clients[slot]=c; atomic_store(&kn_running,count+1);
    pthread_mutex_unlock(&lifecycle);
    if(count==0) kn_notify(KN_DEVICE,kAudioDevicePropertyDeviceIsRunning);
    return noErr;
}
OSStatus kn_stop(AudioServerPlugInDriverRef d,AudioObjectID o,UInt32 c) {
    if(d!=kn_driver || o!=KN_DEVICE) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&lifecycle);
    UInt32 count=atomic_load(&kn_running),slot=count;
    for(UInt32 i=0;i<count;i++) if(clients[i]==c) slot=i;
    if(slot==count) { pthread_mutex_unlock(&lifecycle); return kAudioHardwareIllegalOperationError; }
    clients[slot]=clients[count-1]; atomic_store(&kn_running,--count);
    if(count==0) {
        atomic_fetch_add(&clock_sequence,1); atomic_fetch_add(&kn_epoch,1);
        atomic_fetch_add(&clock_sequence,1);
    }
    pthread_mutex_unlock(&lifecycle);
    if(count==0) kn_notify(KN_DEVICE,kAudioDevicePropertyDeviceIsRunning);
    return noErr;
}
OSStatus kn_zero(AudioServerPlugInDriverRef d,AudioObjectID o,UInt32 c,Float64* sample,UInt64* host,UInt64* seed) {
    (void)c;
    if(d!=kn_driver || o!=KN_DEVICE) return kAudioHardwareBadObjectError;
    if(!sample || !host || !seed || kn_ticks_per_frame<=0) return kAudioHardwareIllegalOperationError;
    UInt64 anchor=0,generation=0; Boolean coherent=false;
    for(UInt32 attempt=0;attempt<3;attempt++) {
        UInt64 before=atomic_load(&clock_sequence);
        if(before&1) continue;
        anchor=atomic_load(&kn_anchor); generation=atomic_load(&kn_epoch);
        if(before==atomic_load(&clock_sequence)) { coherent=true; break; }
    }
    UInt64 now=mach_absolute_time();
    if(!coherent || now<anchor) return kAudioHardwareIllegalOperationError;
    UInt64 periods=(UInt64)((double)(now-anchor)/(kn_ticks_per_frame*KN_PERIOD));
    *sample=(Float64)periods*KN_PERIOD;
    *host=anchor+(UInt64)(*sample*kn_ticks_per_frame); *seed=generation;
    return noErr;
}
OSStatus kn_will(AudioServerPlugInDriverRef d,AudioObjectID o,UInt32 c,UInt32 op,Boolean* yes,Boolean* inplace) {
    (void)c;
    if(d!=kn_driver || o!=KN_DEVICE) return kAudioHardwareBadObjectError;
    if(!yes || !inplace) return kAudioHardwareIllegalOperationError;
    *yes=op==kAudioServerPlugInIOOperationReadInput || op==kAudioServerPlugInIOOperationWriteMix;
    *inplace=true; return noErr;
}
OSStatus kn_cycle(AudioServerPlugInDriverRef d,AudioObjectID o,UInt32 c,UInt32 op,UInt32 frames,const AudioServerPlugInIOCycleInfo* info) {
    (void)c;(void)op;(void)info;
    if(d!=kn_driver || o!=KN_DEVICE) return kAudioHardwareBadObjectError;
    return frames<=KN_CAPACITY?noErr:kAudioHardwareIllegalOperationError;
}
OSStatus kn_io(AudioServerPlugInDriverRef d,AudioObjectID o,AudioObjectID stream,UInt32 c,UInt32 op,
               UInt32 frames,const AudioServerPlugInIOCycleInfo* info,void* buffer,void* secondary) {
    (void)c;(void)secondary;
    if(d!=kn_driver || o!=KN_DEVICE) return kAudioHardwareBadObjectError;
    if(!info || !buffer || frames>KN_CAPACITY) return kAudioHardwareIllegalOperationError;
    Boolean write=op==kAudioServerPlugInIOOperationWriteMix;
    if((write && stream!=KN_OUTPUT) || (!write && stream!=KN_INPUT)) return kAudioHardwareBadObjectError;
    if(!write && op!=kAudioServerPlugInIOOperationReadInput) return kAudioHardwareUnsupportedOperationError;
    if(!atomic_load(&kn_running) || !atomic_load(write?&kn_output_active:&kn_input_active)) {
        if(!write) memset(buffer,0,frames*8);
        return noErr;
    }
    const AudioTimeStamp* time=write?&info->mOutputTime:&info->mInputTime;
    if(!(time->mFlags&kAudioTimeStampSampleTimeValid) || !isfinite(time->mSampleTime)
       || time->mSampleTime<0 || time->mSampleTime>4503599627370496.0) return kAudioHardwareIllegalOperationError;
    UInt64 start=(UInt64)time->mSampleTime,epoch=atomic_load(&kn_epoch);
    float* samples=buffer,volume; UInt32 bits=atomic_load(&kn_gain_bits); memcpy(&volume,&bits,4);
    float gain=atomic_load(&kn_muted)?0:kn_scalar_to_gain(volume);
    /* The mixed output also goes down the private path to the engine, when it is attached. The
       engine's read position only decides whether there is room; slots are always masked. */
    KnLoopback* shared=write?kn_loopback_current():NULL;
    UInt64 shared_write=0;
    if(shared) {
        shared_write=__atomic_load_n(&shared->write,__ATOMIC_RELAXED);
        UInt64 taken=shared_write-__atomic_load_n(&shared->read,__ATOMIC_ACQUIRE);
        if(frames>KN_LOOP_FRAMES || taken>KN_LOOP_FRAMES-frames) {
            __atomic_fetch_add(&shared->dropped,1,__ATOMIC_RELAXED);
            shared=NULL;
        }
    }
    for(UInt32 i=0;i<frames;i++) {
        UInt64 frame=start+i;
        if(!write && frame<KN_DELAY) { samples[2*i]=samples[2*i+1]=0; continue; }
        if(!write) frame-=KN_DELAY;
        KnFrame* slot=&ring[frame%KN_CAPACITY]; UInt64 tag=frame*2+2;
        if(write) {
            atomic_store(&slot->stamp,tag-1);
            float left=samples[2*i]*gain,right=samples[2*i+1]*gain;
            if(shared) {
                UInt64 place=((shared_write+i)&(KN_LOOP_FRAMES-1))*2;
                shared->samples[place]=left; shared->samples[place+1]=right;
            }
            UInt32 l,r; memcpy(&l,&left,4); memcpy(&r,&right,4);
            atomic_store(&slot->left,l); atomic_store(&slot->right,r); atomic_store(&slot->epoch,epoch);
            atomic_store(&slot->stamp,tag);
        } else {
            UInt64 before=atomic_load(&slot->stamp),generation=atomic_load(&slot->epoch);
            UInt32 l=atomic_load(&slot->left),r=atomic_load(&slot->right);
            UInt64 after=atomic_load(&slot->stamp);
            if(before!=tag || after!=tag || generation!=epoch || !atomic_load(&kn_running)) l=r=0;
            memcpy(samples+2*i,&l,4); memcpy(samples+2*i+1,&r,4);
        }
    }
    if(shared) __atomic_store_n(&shared->write,shared_write+frames,__ATOMIC_RELEASE);
    return noErr;
}
