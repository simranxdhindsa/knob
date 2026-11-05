#ifndef KNOB_LOOPBACK_SHARED_H
#define KNOB_LOOPBACK_SHARED_H
#include <stdint.h>

/* The private path from the driver to knob-engine: one ring of stereo float frames at 48 kHz in
   a shared memory block. The driver is the only writer of `write` and the engine of `read`.
   Audio that travels this way never opens the device's input, so macOS shows no microphone dot.
   The block's name is a secret: the engine makes it up, tells only the driver, and removes it
   once the driver is attached, so no other process can open it and hear what the Mac plays. */
enum { KN_LOOP_MAGIC=0x4b4e4c50, KN_LOOP_VERSION=1, KN_LOOP_FRAMES=8192, KN_LOOP_NAME_MAX=31 };
#define KN_LOOP_PREFIX "/knob."
#define KN_ATTACH_SELECTOR 'knsh'

typedef struct {
    uint32_t magic, version, frames, attached;
    uint64_t write __attribute__((aligned(64)));
    uint64_t read __attribute__((aligned(64)));
    uint64_t dropped __attribute__((aligned(64)));
    float samples[KN_LOOP_FRAMES*2] __attribute__((aligned(64)));
} KnLoopback;
#endif
