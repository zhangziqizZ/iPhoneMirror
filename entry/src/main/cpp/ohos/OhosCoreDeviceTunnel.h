#pragma once

#include "OhosUsbMux.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace iPhoneMirror::ohos {

class OhosCoreDeviceTunnel {
public:
    OhosCoreDeviceTunnel();
    ~OhosCoreDeviceTunnel();

    OhosCoreDeviceTunnel(const OhosCoreDeviceTunnel&) = delete;
    OhosCoreDeviceTunnel& operator=(const OhosCoreDeviceTunnel&) = delete;

    bool establish(const std::string& udid);
    void close();
    bool sendHidMessage(const std::vector<std::uint8_t>& frame);

private:
    std::unique_ptr<OhosUsbMux> mux_;
    std::uint16_t tunnelPort_{0};
    bool ready_{false};
};

} // namespace iPhoneMirror::ohos