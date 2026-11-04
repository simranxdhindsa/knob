#pragma once
// Knob's sound for the iPhone app: the same DSPController the Mac engine uses, without the Mac's
// audio devices. Swift reaches it through KnobPhone-Bridging.h. Every function except render
// and peaks is a control call: call them from one queue, never from the audio thread.
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KnobPhoneDSP KnobPhoneDSP;

KnobPhoneDSP *knob_phone_dsp_create(void);
void knob_phone_dsp_destroy(KnobPhoneDSP *dsp);

/// Each returns 0 on success, or 1 with a plain reason copied into `error` (`size` bytes).
int knob_phone_dsp_prepare(KnobPhoneDSP *dsp, int sample_rate, char *error, size_t size);
int knob_phone_dsp_parameter(KnobPhoneDSP *dsp, const char *name, double value, char *error, size_t size);
int knob_phone_dsp_preset(KnobPhoneDSP *dsp, const char *path, char *error, size_t size);
int knob_phone_dsp_save_preset(KnobPhoneDSP *dsp, const char *path, char *error, size_t size);
int knob_phone_dsp_bands(KnobPhoneDSP *dsp, int count, char *error, size_t size);
void knob_phone_dsp_bypass(KnobPhoneDSP *dsp, int bypassed);

/// The controls exactly as the Mac engine reports them under "controls". Returns the length the
/// text needs; it is copied (cut short, always ended) into `json` when it fits in `size`.
size_t knob_phone_dsp_state(KnobPhoneDSP *dsp, char *json, size_t size);

/// Audio thread: processes interleaved stereo samples in place.
void knob_phone_dsp_render(KnobPhoneDSP *dsp, float *interleaved, size_t frames);

/// The loudest sample on each side since the last call, 0...1.
void knob_phone_dsp_peaks(KnobPhoneDSP *dsp, float *left, float *right);

#ifdef __cplusplus
}
#endif
