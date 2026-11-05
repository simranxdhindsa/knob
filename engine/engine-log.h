#pragma once
#include <ctime>
#include <iostream>
#include <string>

namespace knob {
/// One timestamped line in the engine log, which the supervisor sends to engine.log. For the
/// control thread only, never the audio callbacks.
inline void engineLog(const std::string& message) {
    char stamp[16] = {};
    const std::time_t now = std::time(nullptr);
    std::tm local{};
    localtime_r(&now, &local);
    std::strftime(stamp, sizeof(stamp), "%I:%M:%S %p", &local);
    std::cerr << stamp << " knob-engine: " << message << std::endl;
}
}
