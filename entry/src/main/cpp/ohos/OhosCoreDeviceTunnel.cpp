#include "OhosCoreDeviceTunnel.h"

#include "Logging.h"

namespace iPhoneMirror::ohos {

OhosCoreDeviceTunnel::OhosCoreDeviceTunnel() = default;

OhosCoreDeviceTunnel::~OhosCoreDeviceTunnel() {
    close();
}

bool OhosCoreDeviceTunnel::establish(const std::string& /*udid*/) {
    if (ready_) return false;
    mux_ = std::make_unique<OhosUsbMux>();
    if (!mux_->connect(0)) {
        logging::write(logging::Level::Warning, "coredevice",
            "CoreDevice 隧道建立失败：usbmux 连接不可用");
        mux_.reset();
        return false;
    }
    ready_ = false;
    logging::write(logging::Level::Warning, "coredevice",
        "CoreDevice 隧道建立失败：协议尚未完整实现");
    mux_.reset();
    return false;
}

void OhosCoreDeviceTunnel::close() {
    if (mux_) {
        mux_->disconnect();
        mux_.reset();
    }
    ready_ = false;
    tunnelPort_ = 0;
}

bool OhosCoreDeviceTunnel::sendHidMessage(const std::vector<std::uint8_t>& /*frame*/) {
    if (!ready_) return false;
    return false;
}

} // namespace iPhoneMirror::ohos