#include "KnobPhoneDSP.h"
#include "../../engine/dsp-controller.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <exception>
#include <string>

struct KnobPhoneDSP {
    knob::DSPController controller;
    std::atomic<float> peakLeft{0};
    std::atomic<float> peakRight{0};
};

namespace {
void copy(const std::string& text, char* out, size_t size) {
    if (!out || size == 0) return;
    const size_t count = std::min(text.size(), size - 1);
    std::memcpy(out, text.data(), count);
    out[count] = 0;
}

/// Runs a control change the way the Mac engine's command handler does: inside the
/// controller's edit, which waits for the audio thread to step aside.
template <typename Change>
int guarded(KnobPhoneDSP* dsp, char* error, size_t size, Change change) {
    try {
        dsp->controller.edit(change);
        return 0;
    } catch (const std::exception& problem) {
        copy(problem.what(), error, size);
    } catch (...) {
        copy("the sound engine refused the change", error, size);
    }
    return 1;
}

void raise(std::atomic<float>& peak, float value) {
    float seen = peak.load(std::memory_order_relaxed);
    while (value > seen && !peak.compare_exchange_weak(seen, value, std::memory_order_relaxed)) {}
}
}

extern "C" {

KnobPhoneDSP* knob_phone_dsp_create(void) { return new KnobPhoneDSP(); }

void knob_phone_dsp_destroy(KnobPhoneDSP* dsp) { delete dsp; }

int knob_phone_dsp_prepare(KnobPhoneDSP* dsp, int sample_rate, char* error, size_t size) {
    return guarded(dsp, error, size, [&] { dsp->controller.prepare(sample_rate); });
}

int knob_phone_dsp_parameter(KnobPhoneDSP* dsp, const char* name, double value, char* error, size_t size) {
    return guarded(dsp, error, size, [&] { dsp->controller.parameter(name, value); });
}

int knob_phone_dsp_preset(KnobPhoneDSP* dsp, const char* path, char* error, size_t size) {
    return guarded(dsp, error, size, [&] { dsp->controller.preset(path); });
}

int knob_phone_dsp_save_preset(KnobPhoneDSP* dsp, const char* path, char* error, size_t size) {
    return guarded(dsp, error, size, [&] { dsp->controller.savePreset(path); });
}

int knob_phone_dsp_bands(KnobPhoneDSP* dsp, int count, char* error, size_t size) {
    return guarded(dsp, error, size, [&] { dsp->controller.numBands(count); });
}

void knob_phone_dsp_bypass(KnobPhoneDSP* dsp, int bypassed) { dsp->controller.bypass(bypassed != 0); }

size_t knob_phone_dsp_state(KnobPhoneDSP* dsp, char* json, size_t size) {
    const std::string state = dsp->controller.stateJSON();
    if (state.size() < size) copy(state, json, size);
    return state.size() + 1;
}

void knob_phone_dsp_render(KnobPhoneDSP* dsp, float* interleaved, size_t frames) {
    dsp->controller.render(interleaved, frames);
    float left = 0, right = 0;
    for (size_t i = 0; i < frames; ++i) {
        left = std::max(left, std::fabs(interleaved[i * 2]));
        right = std::max(right, std::fabs(interleaved[i * 2 + 1]));
    }
    raise(dsp->peakLeft, std::min(left, 1.0f));
    raise(dsp->peakRight, std::min(right, 1.0f));
}

void knob_phone_dsp_peaks(KnobPhoneDSP* dsp, float* left, float* right) {
    *left = dsp->peakLeft.exchange(0, std::memory_order_relaxed);
    *right = dsp->peakRight.exchange(0, std::memory_order_relaxed);
}

}
