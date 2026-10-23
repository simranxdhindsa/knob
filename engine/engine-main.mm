#include "audio-bridge.h"
#include "command-dispatcher.h"
#include "ipc-server.h"
#include "routing-guard.h"
#include "recovery-channel.h"
#include <csignal>
#include <iostream>
#include <chrono>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/socket.h>

static volatile sig_atomic_t stopping = 0;
static void stopSignal(int) { stopping = 1; }
int main(int argc, char** argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--devices") { std::cout << knob::devicesJSON() << '\n'; return 0; }
        if (argc == 4 && std::string(argv[1]) == "--request") {
            std::cout << knob::IPCServer::request(argv[2], argv[3]) << '\n'; return 0;
        }
        if (argc == 1 || std::string(argv[1]) != "--run" || argc < 3) {
            std::cerr << "Usage: knob-engine --devices | --request SOCKET JSON | --run OUTPUT_UID [--activate] [--socket PATH]\n";
            return 2;
        }
        std::string outputUID = argv[2], socketPath = knob::defaultSocketPath(); bool activate = false;
        std::string presetPath, fallbackPreset;
        int recoveryFD = -1;
        for (int i = 3; i < argc; ++i) {
            std::string arg = argv[i];
            if (arg == "--activate") activate = true;
            else if (arg == "--socket" && i + 1 < argc) socketPath = argv[++i];
            else if (arg == "--preset" && i + 1 < argc) presetPath = argv[++i];
            else if (arg == "--fallback-preset" && i + 1 < argc) fallbackPreset = argv[++i];
            else if (arg == "--recovery-fd" && i + 1 < argc) recoveryFD = std::stoi(argv[++i]);
            else throw std::runtime_error("unknown or incomplete engine option");
        }
        if (outputUID == knob::virtualUID) throw std::runtime_error("virtual output would cause feedback");
        std::signal(SIGINT, stopSignal); std::signal(SIGTERM, stopSignal);
        std::signal(SIGPIPE, SIG_IGN);
        knob::RoutingGuard routing;
        if (recoveryFD >= 0) {
            struct stat channelInfo{};
            int socketType = 0; socklen_t typeSize = sizeof(socketType);
            if (fstat(recoveryFD, &channelInfo) || !S_ISSOCK(channelInfo.st_mode) ||
                getsockopt(recoveryFD, SOL_SOCKET, SO_TYPE, &socketType, &typeSize) || socketType != SOCK_DGRAM ||
                fcntl(recoveryFD, F_SETFD, FD_CLOEXEC))
                throw std::runtime_error("invalid supervisor recovery channel");
            routing.recoverySink([recoveryFD](const std::string& uid) { knob::notifyRecovery(recoveryFD, uid); });
        }
        knob::DSPController dsp;
        knob::AudioBridge bridge;
        dsp.prepare(bridge, outputUID);
        if (!presetPath.empty()) {
            try { dsp.edit([&] { dsp.preset(presetPath); }); }
            catch (...) {
                if (fallbackPreset.empty()) throw;
                std::cerr << "knob-engine: saved preset unavailable; loading fallback preset\n";
                dsp.edit([&] { dsp.preset(fallbackPreset); });
            }
        }
        bridge.start(outputUID);
        knob::IPCServer server(socketPath);
        bool shutdown = false;
        while (!stopping && !shutdown) {
            server.poll([&](const std::string& request) {
                return knob::dispatchCommand(request, bridge, routing, dsp, outputUID, activate, shutdown);
            });
            if (routing.owned() && knob::deviceUID(knob::defaultOutput()) != knob::virtualUID) {
                activate = false; routing.restore();
            }
            if (bridge.changed()) {
                routing.restore(); dsp.prepare(bridge, outputUID); bridge.start(outputUID);
            }
            if (activate && !routing.owned() && bridge.ready()) routing.activate(bridge.inputDevice());
            // Measured from the latest IO start, so switching outputs gets the same 5 seconds.
            if (!bridge.ready() && std::chrono::steady_clock::now() - bridge.startedAt() > std::chrono::seconds(5))
                throw std::runtime_error("capture/render readiness timed out; default output was not activated");
        }
        routing.restore(); bridge.stop();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "knob-engine: " << error.what() << '\n'; return 1;
    }
}
