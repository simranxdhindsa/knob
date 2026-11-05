#pragma once
#include "../driver/src/loopback-shared.h"
#include "stereo-ring.h"
#include <CoreAudio/CoreAudio.h>
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <string>
#include <thread>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace knob {
/// The driver's private path to the engine (driver/src/loopback-shared.h): the same ring calls as
/// StereoRing, on a shared memory block the driver writes into. Reading it opens no audio input,
/// so macOS shows no microphone dot. `open` and `close` are for the control thread; the ring
/// calls are for the render thread and never block.
class SharedLoopback {
public:
    SharedLoopback() = default;
    SharedLoopback(const SharedLoopback&) = delete;
    SharedLoopback& operator=(const SharedLoopback&) = delete;
    ~SharedLoopback() { unmap(); }

    /// Makes a block with a secret name and hands the name to the driver. False means this
    /// driver has no private path, or it could not attach: the caller captures as before.
    bool open(AudioDeviceID device) noexcept {
        close(device);
        if (!supported(device)) return false;
        const auto name = secretName();
        const int file = shm_open(name.c_str(), O_CREAT | O_EXCL | O_RDWR, 0666);
        if (file < 0) return false;
        // The driver runs as another user; the secret name, removed below, is what guards the block.
        fchmod(file, 0666);
        void* mapped = MAP_FAILED;
        if (ftruncate(file, sizeof(KnLoopback)) == 0)
            mapped = mmap(nullptr, sizeof(KnLoopback), PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
        ::close(file);
        if (mapped == MAP_FAILED) { shm_unlink(name.c_str()); return false; }
        block_ = static_cast<KnLoopback*>(mapped);
        block_->magic = KN_LOOP_MAGIC; block_->version = KN_LOOP_VERSION; block_->frames = KN_LOOP_FRAMES;
        bool attached = tell(device, name);
        for (int wait = 0; attached && wait < 200 && !__atomic_load_n(&block_->attached, __ATOMIC_ACQUIRE); ++wait)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        attached = attached && __atomic_load_n(&block_->attached, __ATOMIC_ACQUIRE);
        shm_unlink(name.c_str());
        if (!attached) unmap();
        return attached;
    }
    void close(AudioDeviceID device) noexcept {
        if (!block_) return;
        tell(device, "");
        unmap();
    }
    bool active() const noexcept { return block_ != nullptr; }

    uint64_t available() const noexcept {
        const auto write = __atomic_load_n(&block_->write, __ATOMIC_ACQUIRE);
        const auto read = __atomic_load_n(&block_->read, __ATOMIC_RELAXED);
        return write >= read ? std::min<uint64_t>(write - read, KN_LOOP_FRAMES) : 0;
    }
    StereoFrame peek(uint64_t offset) const noexcept {
        const auto place = ((__atomic_load_n(&block_->read, __ATOMIC_RELAXED) + offset) & (KN_LOOP_FRAMES - 1)) * 2;
        return {block_->samples[place], block_->samples[place + 1]};
    }
    void consume(uint64_t count) noexcept {
        __atomic_store_n(&block_->read, __atomic_load_n(&block_->read, __ATOMIC_RELAXED) + count, __ATOMIC_RELEASE);
    }
    /// Skips what built up during a stall, so the sound never lags behind for good. The driver
    /// runs on its own clock, so nothing else would bring the delay back down.
    void trim(uint64_t limit, uint64_t keep) noexcept {
        const auto waiting = available();
        if (waiting > limit) consume(waiting - keep);
    }
    uint64_t written() const noexcept { return __atomic_load_n(&block_->write, __ATOMIC_RELAXED); }
    uint64_t dropped() const noexcept { return __atomic_load_n(&block_->dropped, __ATOMIC_RELAXED); }

    /// Wraps a block made elsewhere (the tests' stand in for the driver).
    void adopt(KnLoopback* block) noexcept { unmap(); block_ = block; borrowed_ = true; }

private:
    static AudioObjectPropertyAddress attachAddress() noexcept {
        return {KN_ATTACH_SELECTOR, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    }
    static bool supported(AudioDeviceID device) noexcept {
        AudioObjectPropertyAddress address{'knvr', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFStringRef version = nullptr;
        UInt32 size = sizeof(version);
        if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &version) != noErr || !version) return false;
        const bool fits = CFStringGetIntValue(version) >= 2;
        CFRelease(version);
        return fits;
    }
    static bool tell(AudioDeviceID device, const std::string& name) noexcept {
        CFStringRef text = CFStringCreateWithCString(nullptr, name.c_str(), kCFStringEncodingUTF8);
        if (!text) return false;
        const auto address = attachAddress();
        const bool told = AudioObjectSetPropertyData(device, &address, 0, nullptr, sizeof(text), &text) == noErr;
        CFRelease(text);
        return told;
    }
    /// "/knob." and 20 random letters and digits: within the 31 characters macOS allows.
    static std::string secretName() {
        static constexpr char letters[] = "abcdefghijklmnopqrstuvwxyz234567";
        std::string name = KN_LOOP_PREFIX;
        unsigned char bytes[20];
        arc4random_buf(bytes, sizeof(bytes));
        for (const auto byte : bytes) name += letters[byte % 32];
        return name;
    }
    void unmap() noexcept {
        if (block_ && !borrowed_) munmap(block_, sizeof(KnLoopback));
        block_ = nullptr; borrowed_ = false;
    }
    KnLoopback* block_ = nullptr;
    bool borrowed_ = false;
};
}
