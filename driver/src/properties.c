#include "driver.h"
#include "loopback.h"
#include <math.h>

Boolean kn_object(AudioObjectID o) { return o>=kAudioObjectPlugInObject && o<=KN_SOURCE; }
OSStatus kn_copy(UInt32* n, void* out, const void* value, UInt32 size) {
    if(out && *n<size) return kAudioHardwareBadPropertySizeError;
    if(out && size) memcpy(out,value,size);
    *n=size; return noErr;
}
OSStatus kn_string(UInt32* n, void* out, CFStringRef value) {
    if(out && *n<sizeof(value)) return kAudioHardwareBadPropertySizeError;
    if(out) { CFRetain(value); memcpy(out,&value,sizeof(value)); }
    *n=sizeof(value); return noErr;
}
AudioStreamBasicDescription kn_format(void) {
    return (AudioStreamBasicDescription){48000,kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked,8,1,8,2,32,0};
}
void kn_notify(AudioObjectID o, AudioObjectPropertySelector s) {
    AudioObjectPropertyAddress a={s,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    if(kn_host) kn_host->PropertiesChanged(kn_host,o,1,&a);
}
Boolean kn_settable(AudioObjectID o, AudioObjectPropertySelector s) {
    return (o==KN_VOLUME && (s==kAudioLevelControlPropertyScalarValue || s==kAudioLevelControlPropertyDecibelValue))
        || (o==KN_MUTE && s==kAudioBooleanControlPropertyValue)
        || (o==KN_SOURCE && s==kAudioSelectorControlPropertyCurrentItem)
        || (o==KN_DEVICE && s==KN_ATTACH)
        || ((o==KN_INPUT || o==KN_OUTPUT) && s==kAudioStreamPropertyIsActive);
}
OSStatus kn_value(AudioObjectID o,const AudioObjectPropertyAddress* a,UInt32 qn,const void* q,UInt32* n,void* out) {
    if(!a || !n) return kAudioHardwareIllegalOperationError;
    if(!kn_object(o)) return kAudioHardwareBadObjectError;
    if(a->mElement!=kAudioObjectPropertyElementMain) return kAudioHardwareUnknownPropertyError;
    if(a->mScope!=kAudioObjectPropertyScopeGlobal &&
       (o!=KN_DEVICE || (a->mScope!=kAudioObjectPropertyScopeInput && a->mScope!=kAudioObjectPropertyScopeOutput)))
        return kAudioHardwareUnknownPropertyError;
    if(o==KN_SOURCE && a->mSelector==kAudioSelectorControlPropertyItemName) {
        if(!out) { *n=sizeof(CFStringRef); return noErr; }
        UInt32 item=0;
        if(qn!=sizeof(item) || !q) return kAudioHardwareBadPropertySizeError;
        memcpy(&item,q,4);
        if(item!=1) return kAudioHardwareIllegalOperationError;
        return kn_string(n,out,CFSTR("Knob"));
    }
    UInt32 v=0;
    switch(a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        v=o==1?kAudioObjectClassID:o==KN_DEVICE?kAudioObjectClassID:
          o<=KN_OUTPUT?kAudioObjectClassID:o==KN_VOLUME?kAudioLevelControlClassID:
          o==KN_MUTE?kAudioBooleanControlClassID:kAudioSelectorControlClassID; break;
    case kAudioObjectPropertyClass:
        v=o==1?kAudioPlugInClassID:o==KN_DEVICE?kAudioDeviceClassID:
          o<=KN_OUTPUT?kAudioStreamClassID:o==KN_VOLUME?kAudioVolumeControlClassID:
          o==KN_MUTE?kAudioMuteControlClassID:kAudioDataSourceControlClassID; break;
    case kAudioObjectPropertyOwner: v=o==1?0:o==KN_DEVICE?1:KN_DEVICE; break;
    case kAudioObjectPropertyManufacturer: return kn_string(n,out,CFSTR("Knob"));
    case kAudioObjectPropertyName:
        return kn_string(n,out,o==KN_INPUT?CFSTR("Knob Loopback"):
            o==KN_OUTPUT?CFSTR("Knob Output"):CFSTR("Knob"));
    default:
        if(o<=KN_DEVICE) return kn_device_value(o,a,qn,q,n,out);
        return kn_stream_control_value(o,a,n,out);
    }
    return kn_copy(n,out,&v,sizeof(v));
}
OSStatus kn_set(AudioObjectID o,const AudioObjectPropertyAddress* a,UInt32 n,const void* data) {
    if(!a || !data) return kAudioHardwareIllegalOperationError;
    if(!kn_settable(o,a->mSelector)) return kAudioHardwareUnsupportedOperationError;
    if(o==KN_DEVICE) {
        CFStringRef name=NULL;
        if(n!=sizeof(name)) return kAudioHardwareBadPropertySizeError;
        memcpy(&name,data,sizeof(name));
        return kn_loopback_attach(name);
    }
    if(n!=sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
    UInt32 v; memcpy(&v,data,4);
    if(o==KN_VOLUME) {
        float value; memcpy(&value,data,4);
        if(!isfinite(value)) return kAudioHardwareIllegalOperationError;
        if(a->mSelector==kAudioLevelControlPropertyDecibelValue) {
            if(value > 0) return kAudioHardwareIllegalOperationError;
            value=kn_db_to_scalar(value);
        }
        if(value<0 || value>1) return kAudioHardwareIllegalOperationError;
        memcpy(&v,&value,4); atomic_store(&kn_gain_bits,v);
        kn_notify(o,kAudioLevelControlPropertyScalarValue);
        kn_notify(o,kAudioLevelControlPropertyDecibelValue);
    } else if(o==KN_MUTE) {
        if(v>1) return kAudioHardwareIllegalOperationError;
        atomic_store(&kn_muted,v); kn_notify(o,a->mSelector);
    } else if(o==KN_SOURCE) {
        if(v!=1) return kAudioHardwareIllegalOperationError;
    } else {
        if(v>1) return kAudioHardwareIllegalOperationError;
        atomic_store(o==KN_INPUT?&kn_input_active:&kn_output_active,v); kn_notify(o,a->mSelector);
    }
    return noErr;
}
