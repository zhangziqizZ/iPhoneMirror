#pragma once

#include "OhosUsbDdk.h"

#include <cstdint>
#include <vector>

namespace iPhoneMirror::ohos {

class OhosUsbMux {
public:
    OhosUsbMux();
    ~OhosUsbMux();

    OhosUsbMux(const OhosUsbMux&) = delete;
    OhosUsbMux& operator=(const OhosUsbMux&) = delete;

    bool connect(std::uint64_t deviceId);
    void disconnect();
    int send(const std::vector<std::uint8_t>& data);
    std::vector<std::uint8_t> receive(int timeoutMs);

private:
    ohos_usb::DdkSession ddkSession_;
    std::uint64_t deviceId_{0};
    std::uint64_t interfaceHandle_{0};
    bool connected_{false};
};

} // namespace iPhoneMirror::ohos