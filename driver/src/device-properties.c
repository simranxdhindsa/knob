#include "driver.h"

OSStatus kn_device_value(AudioObjectID o,const AudioObjectPropertyAddress* a,
                         UInt32 qn,const void* q,UInt32* n,void* out) {
    UInt32 v=0; AudioObjectID ids[]={KN_INPUT,KN_OUTPUT,KN_VOLUME,KN_MUTE,KN_SOURCE};
    Boolean input=a->mScope==kAudioObjectPropertyScopeInput;
    Boolean output=a->mScope==kAudioObjectPropertyScopeOutput;
    Boolean global=a->mScope==kAudioObjectPropertyScopeGlobal;
    if(!input && !output && !global) return kAudioHardwareUnknownPropertyError;
    if(o==kAudioObjectPlugInObject) {
        switch(a->mSelector) {
        case kAudioPlugInPropertyBundleID: return kn_string(n,out,CFSTR("io.github.simranxdhindsa.knob.virtual-audio"));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: v=KN_DEVICE; break;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CFStringRef uid=NULL;
            if(!out) { *n=sizeof(UInt32); return noErr; }
            if(qn!=sizeof(uid) || !q) return kAudioHardwareBadPropertySizeError;
            memcpy(&uid,q,sizeof(uid));
            if(uid && CFEqual(uid,CFSTR("Knob_Virtual"))) v=KN_DEVICE;
            break;
        }
        case kAudioPlugInPropertyBoxList: return kn_copy(n,out,NULL,0);
        default: return kAudioHardwareUnknownPropertyError;
        }
        return kn_copy(n,out,&v,sizeof(v));
    }
    switch(a->mSelector) {
    case kAudioDevicePropertyDeviceUID: return kn_string(n,out,CFSTR("Knob_Virtual"));
    case kAudioDevicePropertyModelUID: return kn_string(n,out,CFSTR("Knob_Mac_Stereo48"));
    case kAudioDevicePropertyTransportType: v=kAudioDeviceTransportTypeVirtual; break;
    case kAudioDevicePropertyClockDomain: v=0; break;
    case kAudioDevicePropertyDeviceIsAlive: v=1; break;
    case kAudioDevicePropertyDeviceIsRunning: v=atomic_load(&kn_running)>0; break;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: v=1; break;
    case kAudioDevicePropertyIsHidden: v=0; break;
    case kAudioDevicePropertyLatency: v=input?KN_DELAY:0; break;
    case kAudioDevicePropertySafetyOffset: v=0; break;
    case kAudioDevicePropertyZeroTimeStampPeriod: v=KN_PERIOD; break;
    case KN_VERSION: return kn_string(n,out,CFSTR("2"));
    /* Write only: the private block's name is never read back. */
    case KN_ATTACH: return kn_string(n,out,CFSTR(""));
    case kAudioDevicePropertyNominalSampleRate: {
        Float64 rate=48000; return kn_copy(n,out,&rate,sizeof(rate));
    }
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range={48000,48000}; return kn_copy(n,out,&range,sizeof(range));
    }
    case kAudioDevicePropertyRelatedDevices: v=KN_DEVICE; break;
    case kAudioObjectPropertyOwnedObjects:
        if(global) return kn_copy(n,out,ids,sizeof(ids));
        if(input) return kn_copy(n,out,ids,sizeof(AudioObjectID));
        return kn_copy(n,out,ids+1,4*sizeof(AudioObjectID));
    case kAudioDevicePropertyStreams:
        if(global) return kn_copy(n,out,ids,2*sizeof(AudioObjectID));
        return kn_copy(n,out,ids+(input?0:1),sizeof(AudioObjectID));
    case kAudioObjectPropertyControlList:
        return kn_copy(n,out,ids+2,3*sizeof(AudioObjectID));
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32 channels[]={1,2}; return kn_copy(n,out,channels,sizeof(channels));
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        AudioChannelLayout layout={kAudioChannelLayoutTag_Stereo,0,0,{{0}}};
        return kn_copy(n,out,&layout,offsetof(AudioChannelLayout,mChannelDescriptions));
    }
    case kAudioDevicePropertyStreamConfiguration: {
        AudioBufferList buffers={1,{{2,0,NULL}}}; return kn_copy(n,out,&buffers,sizeof(buffers));
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        AudioServerPlugInCustomPropertyInfo info[]={
            {KN_VERSION,kAudioServerPlugInCustomPropertyDataTypeCFString,kAudioServerPlugInCustomPropertyDataTypeNone},
            {KN_ATTACH,kAudioServerPlugInCustomPropertyDataTypeCFString,kAudioServerPlugInCustomPropertyDataTypeNone}};
        return kn_copy(n,out,info,sizeof(info));
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
    return kn_copy(n,out,&v,sizeof(v));
}
