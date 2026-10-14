#pragma once

#include "iPhoneMirror/CoreApi.h"
#include "OhosCoreDeviceTunnel.h"
#include "OhosHidMessage.h"

#include <cstdint>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace iPhoneMirror::ohos {

class OhosInputBridge {
public:
    OhosInputBridge();
    ~OhosInputBridge();

    OhosInputBridge(const OhosInputBridge&) = delete;
    OhosInputBridge& operator=(const OhosInputBridge&) = delete;

    std::int32_t start(const wchar_t* udid);
    std::int32_t stop();
    std::int32_t sendTouch(const TouchPoint* points, std::uint32_t count);
    std::int32_t sendKeyboard(const std::uint8_t* usages, std::uint32_t count,
        std::int32_t releaseAll);
    std::int32_t sendButton(std::uint16_t usagePage, std::uint16_t usageCode,
        const char* state);
    std::int32_t getStatus(ReverseControlStatus* status);

private:
    void releaseAllContacts();
    void releaseAllKeys();
    void releaseAllButtons();

    ReverseControlState state_{ReverseControlState::Idle};
    std::string lastErrorCode_;
    std::string lastErrorMessage_;
    std::set<std::int32_t> activeTouchContacts_;
    std::set<std::uint8_t> pressedKeys_;
    std::set<std::uint16_t> pressedButtons_;
    std::mutex sendLock_;
    std::int64_t generation_{1};
    std::uint64_t seq_{0};
    std::unique_ptr<OhosCoreDeviceTunnel> tunnel_;
    OhosHidMessage hidMessage_;
};

} // namespace iPhoneMirror::ohos