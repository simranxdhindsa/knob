#include "driver.h"
#include <math.h>

OSStatus kn_stream_control_value(AudioObjectID o,const AudioObjectPropertyAddress* a,UInt32* n,void* out) {
    UInt32 v=0;
    if(a->mScope!=kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
    if(o<=KN_OUTPUT) {
        switch(a->mSelector) {
        case kAudioObjectPropertyOwnedObjects: return kn_copy(n,out,NULL,0);
        case kAudioStreamPropertyIsActive: v=atomic_load(o==KN_INPUT?&kn_input_active:&kn_output_active); break;
        case kAudioStreamPropertyDirection: v=o==KN_INPUT; break;
        case kAudioStreamPropertyTerminalType: v=kAudioStreamTerminalTypeLine; break;
        case kAudioStreamPropertyStartingChannel: v=1; break;
        case kAudioStreamPropertyLatency: v=0; break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f=kn_format(); return kn_copy(n,out,&f,sizeof(f));
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription f={kn_format(),{48000,48000}};
            return kn_copy(n,out,&f,sizeof(f));
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    } else {
        switch(a->mSelector) {
        case kAudioObjectPropertyOwnedObjects: return kn_copy(n,out,NULL,0);
        case kAudioControlPropertyScope: v=kAudioObjectPropertyScopeOutput; break;
        case kAudioControlPropertyElement: v=kAudioObjectPropertyElementMain; break;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue: {
            if(o!=KN_VOLUME) return kAudioHardwareUnknownPropertyError;
            UInt32 bits=atomic_load(&kn_gain_bits); float f; memcpy(&f,&bits,4);
            if(a->mSelector==kAudioLevelControlPropertyDecibelValue) f=kn_scalar_to_db(f);
            return kn_copy(n,out,&f,sizeof(f));
        }
        case kAudioLevelControlPropertyDecibelRange: {
            if(o!=KN_VOLUME) return kAudioHardwareUnknownPropertyError;
            AudioValueRange r={KN_MIN_DB,0}; return kn_copy(n,out,&r,sizeof(r));
        }
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            if(o!=KN_VOLUME) return kAudioHardwareUnknownPropertyError;
            if(out && *n<sizeof(float)) return kAudioHardwareBadPropertySizeError;
            if(out) {
                float f; memcpy(&f,out,4);
                if(!isfinite(f)) return kAudioHardwareIllegalOperationError;
                f=a->mSelector==kAudioLevelControlPropertyConvertScalarToDecibels?
                    kn_scalar_to_db(f):kn_db_to_scalar(f);
                memcpy(out,&f,4);
            }
            *n=4; return noErr;
        }
        case kAudioBooleanControlPropertyValue:
            if(o!=KN_MUTE) return kAudioHardwareUnknownPropertyError;
            v=atomic_load(&kn_muted); break;
        case kAudioSelectorControlPropertyCurrentItem:
        case kAudioSelectorControlPropertyAvailableItems:
            if(o!=KN_SOURCE) return kAudioHardwareUnknownPropertyError;
            v=1; break;
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    return kn_copy(n,out,&v,sizeof(v));
}
