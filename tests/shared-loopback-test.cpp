#include "../engine/adaptive-resampler.h"
#include "../engine/shared-loopback.h"
#include <cassert>
#include <memory>

using namespace knob;

// The driver's side of the ring, as driver/src/audio-io.c writes it.
static bool push(KnLoopback& block, uint32_t frames, float value) {
    const auto write = __atomic_load_n(&block.write, __ATOMIC_RELAXED);
    const auto taken = write - __atomic_load_n(&block.read, __ATOMIC_ACQUIRE);
    if (frames > KN_LOOP_FRAMES || taken > KN_LOOP_FRAMES - frames) return false;
    for (uint32_t i = 0; i < frames; ++i) {
        const auto place = ((write + i) & (KN_LOOP_FRAMES - 1)) * 2;
        block.samples[place] = value; block.samples[place + 1] = -value;
    }
    __atomic_store_n(&block.write, write + frames, __ATOMIC_RELEASE);
    return true;
}

int main() {
    static_assert((KN_LOOP_FRAMES & (KN_LOOP_FRAMES - 1)) == 0, "slots are masked");
    auto block = std::make_unique<KnLoopback>();
    SharedLoopback ring;
    ring.adopt(block.get());
    assert(ring.active() && ring.available() == 0);

    assert(push(*block, 512, 0.5f));
    assert(ring.available() == 512);
    assert(ring.peek(0).left == 0.5f && ring.peek(0).right == -0.5f);
    ring.consume(512);
    assert(ring.available() == 0);

    // A full ring refuses new audio instead of overwriting what is being read.
    assert(push(*block, KN_LOOP_FRAMES, 0.25f));
    assert(!push(*block, 1, 0.25f));
    assert(ring.available() == KN_LOOP_FRAMES);

    // After a stall the delay comes back down, keeping the newest audio.
    ring.trim(4096, 1024);
    assert(ring.available() == 1024);
    ring.trim(4096, 1024);
    assert(ring.available() == 1024);
    ring.consume(1024);

    // Across the wrap the frames stay in order.
    assert(push(*block, 100, 0.75f));
    assert(ring.peek(99).left == 0.75f);
    ring.consume(100);

    // The resampler reads this ring as it does StereoRing, and waits for enough audio to start.
    AdaptiveResampler resampler;
    resampler.prepare(48000);
    StereoFrame frame;
    assert(!resampler.next(ring, frame));
    assert(push(*block, AdaptiveResampler::targetFrames, 0.125f));
    assert(resampler.next(ring, frame) && frame.left == 0.125f);
    return 0;
}
