#ifndef KNOB_LOOPBACK_H
#define KNOB_LOOPBACK_H
#include "loopback-shared.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/AudioHardwareBase.h>

/* Attaches to the block with this name, or detaches for an empty name. Not for the audio thread. */
OSStatus kn_loopback_attach(CFStringRef name);
/* The attached block, or NULL. Safe on the audio thread. */
KnLoopback* kn_loopback_current(void);
#endif
