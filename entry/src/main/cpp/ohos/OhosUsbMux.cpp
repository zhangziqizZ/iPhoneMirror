#include "OhosUsbMux.h"

#include "Logging.h"

namespace iPhoneMirror::ohos {

OhosUsbMux::OhosUsbMux() = default;

OhosUsbMux::~OhosUsbMux() {
    disconnect();
}

bool OhosUsbMux::connect(std::uint64_t deviceId) {
    if (connected_) return false;
    if (!ddkSession_.ok()) {
        logging::write(logging::Level::Warning, "usbmux",
            "USB DDK 不可用，无法建立 usbmux 连接");
        return false;
    }
    deviceId_ = deviceId;
    connected_ = false;
    logging::write(logging::Level::Warning, "usbmux",
        "usbmux connect: DDK 可用但 usbmux 协议尚未完整实现");
    return false;
}

void OhosUsbMux::disconnect() {
    connected_ = false;
    interfaceHandle_ = 0;
    deviceId_ = 0;
}

int OhosUsbMux::send(const std::vector<std::uint8_t>& data) {
    if (!connected_) return -1;
    return -1;
}

std::vector<std::uint8_t> OhosUsbMux::receive(int /*timeoutMs*/) {
    if (!connected_) return {};
    return {};
}

} // namespace iPhoneMirror::ohos