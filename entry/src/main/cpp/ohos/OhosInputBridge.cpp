#include "OhosInputBridge.h"

#include "Logging.h"
#include "Text/Utf.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace iPhoneMirror::ohos {

namespace {
bool validAction(const char* action) {
    return action != nullptr &&
        (std::strcmp(action, "down") == 0 ||
         std::strcmp(action, "move") == 0 ||
         std::strcmp(action, "up") == 0);
}

bool validButtonState(const char* state) {
    return state != nullptr &&
        (std::strcmp(state, "down") == 0 ||
         std::strcmp(state, "up") == 0 ||
         std::strcmp(state, "canceled") == 0);
}

bool validButtonUsage(std::uint16_t usagePage, std::uint16_t usageCode) {
    if (usagePage == 0x0C) {
        return usageCode == 0x40 || usageCode == 0x30 ||
               usageCode == 0xE9 || usageCode == 0xEA ||
               usageCode == 0xE2 || usageCode == 0xCF;
    }
    return false;
}
}

OhosInputBridge::OhosInputBridge() = default;

OhosInputBridge::~OhosInputBridge() {
    stop();
}

std::int32_t OhosInputBridge::start(const wchar_t* udid) {
    if (udid == nullptr || *udid == L'\0') {
        lastErrorCode_ = "InvalidArgument";
        lastErrorMessage_ = "udid 不能为空";
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    std::scoped_lock lock(sendLock_);
    if (state_ != ReverseControlState::Idle) {
        lastErrorCode_ = "SessionAlreadyExists";
        lastErrorMessage_ = "反向控制通道已在运行";
        return static_cast<std::int32_t>(Result::SessionAlreadyExists);
    }
    // 每次开启新的反向控制会话都推进输入生命周期代号并重置序号，防止上一会话
    // 残留的排队 HID 帧带着相同 generation 被新会话接收（对应上游 1.8.5
    // "Keep host input lifetimes distinct across child-process restarts so queued
    //  input and clipboard requests cannot enter a later session with a reused
    //  protocol counter" 的等价加固）。generation 由 OhosHidMessage 编码进每帧。
    ++generation_;
    seq_ = 0;
    state_ = ReverseControlState::Connecting;
    tunnel_ = std::make_unique<OhosCoreDeviceTunnel>();
    const std::string udidUtf8 = text::wide_to_utf8(udid);
    if (!tunnel_->establish(udidUtf8)) {
        state_ = ReverseControlState::Error;
        lastErrorCode_ = "CaptureBackendUnavailable";
        lastErrorMessage_ = "CoreDevice 隧道建立失败";
        tunnel_.reset();
        return static_cast<std::int32_t>(Result::CaptureBackendUnavailable);
    }
    state_ = ReverseControlState::Ready;
    lastErrorCode_.clear();
    lastErrorMessage_.clear();
    return static_cast<std::int32_t>(Result::Ok);
}

std::int32_t OhosInputBridge::stop() {
    std::scoped_lock lock(sendLock_);
    if (state_ == ReverseControlState::Idle) {
        return static_cast<std::int32_t>(Result::Ok);
    }
    releaseAllContacts();
    releaseAllKeys();
    releaseAllButtons();
    if (tunnel_) {
        tunnel_->close();
        tunnel_.reset();
    }
    state_ = ReverseControlState::Idle;
    lastErrorCode_.clear();
    lastErrorMessage_.clear();
    return static_cast<std::int32_t>(Result::Ok);
}

std::int32_t OhosInputBridge::sendTouch(const TouchPoint* points, std::uint32_t count) {
    if (points == nullptr || count == 0) {
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    if (count > MaxTouchSlots) {
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    for (std::uint32_t i = 0; i < count; ++i) {
        if (!validAction(points[i].action)) {
            return static_cast<std::int32_t>(Result::InvalidArgument);
        }
        // ★ 必须显式判 isfinite：IEEE-754 下 `NaN < 0.0f` 与 `NaN > 1.0f`
        //   **都是 false**，光靠上下界比较放不放不住 NaN；±Inf 也只被挡住一半。
        //   漏过去的 NaN 最终进 std::to_string(float) ⇒ 拼出 `{"x":nan}` 这种
        //   非法 JSON，对端整条报文拒绝，界面上只表现为"点了没反应"。
        const bool finite = std::isfinite(points[i].normalizedX) &&
            std::isfinite(points[i].normalizedY);
        if (!finite ||
            points[i].normalizedX < 0.0f || points[i].normalizedX > 1.0f ||
            points[i].normalizedY < 0.0f || points[i].normalizedY > 1.0f) {
            return static_cast<std::int32_t>(Result::InvalidArgument);
        }
    }
    std::scoped_lock lock(sendLock_);
    if (state_ != ReverseControlState::Ready) {
        return static_cast<std::int32_t>(Result::CaptureBackendUnavailable);
    }
    for (std::uint32_t i = 0; i < count; ++i) {
        if (std::strcmp(points[i].action, "down") == 0) {
            activeTouchContacts_.insert(points[i].pointerId);
        } else if (std::strcmp(points[i].action, "up") == 0) {
            activeTouchContacts_.erase(points[i].pointerId);
        }
    }
    const auto frame = hidMessage_.formatTouchBatch(points, count, generation_, ++seq_);
    if (!tunnel_ || !tunnel_->sendHidMessage(frame)) {
        state_ = ReverseControlState::Error;
        lastErrorCode_ = "CaptureBackendUnavailable";
        lastErrorMessage_ = "触摸事件发送失败";
        return static_cast<std::int32_t>(Result::CaptureBackendUnavailable);
    }
    return static_cast<std::int32_t>(Result::Ok);
}

std::int32_t OhosInputBridge::sendKeyboard(const std::uint8_t* usages, std::uint32_t count,
    std::int32_t releaseAll) {
    // ★ 与 im_send_keyboard 同一条判据："没给数组 ⇒ count 必须为 0"。
    //   写成 `usages == nullptr && releaseAll == 0` 会放行
    //   `nullptr + releaseAll != 0`，下面 formatKeyboardBatch 的 usages[i] 就是 UAF。
    if (usages == nullptr && count != 0) {
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    if (count > MaxKeyboardUsages) {
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    std::scoped_lock lock(sendLock_);
    if (state_ != ReverseControlState::Ready) {
        return static_cast<std::int32_t>(Result::CaptureBackendUnavailable);
    }
    if (releaseAll != 0) {
        pressedKeys_.clear();
    } else if (usages != nullptr) {
        pressedKeys_.clear();
        for (std::uint32_t i = 0; i < count; ++i) {
            pressedKeys_.insert(usages[i]);
        }
    }
    const auto frame = hidMessage_.formatKeyboardBatch(usages, count, releaseAll,
        generation_, ++seq_);
    if (!tunnel_ || !tunnel_->sendHidMessage(frame)) {
        state_ = ReverseControlState::Error;
        lastErrorCode_ = "CaptureBackendUnavailable";
        lastErrorMessage_ = "键盘事件发送失败";
        return static_cast<std::int32_t>(Result::CaptureBackendUnavailable);
    }
    return static_cast<std::int32_t>(Result::Ok);
}

std::int32_t OhosInputBridge::sendButton(std::uint16_t usagePage, std::uint16_t usageCode,
    const char* state) {
    if (!validButtonState(state)) {
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    if (!validButtonUsage(usagePage, usageCode)) {
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    std::scoped_lock lock(sendLock_);
    if (state_ != ReverseControlState::Ready) {
        return static_cast<std::int32_t>(Result::CaptureBackendUnavailable);
    }
    const std::uint16_t buttonKey = (static_cast<std::uint16_t>(usagePage) << 8) | usageCode;
    if (std::strcmp(state, "down") == 0) {
        pressedButtons_.insert(buttonKey);
    } else {
        pressedButtons_.erase(buttonKey);
    }
    const auto frame = hidMessage_.formatButtonEvent(usagePage, usageCode, state,
        generation_, ++seq_);
    if (!tunnel_ || !tunnel_->sendHidMessage(frame)) {
        state_ = ReverseControlState::Error;
        lastErrorCode_ = "CaptureBackendUnavailable";
        lastErrorMessage_ = "按钮事件发送失败";
        return static_cast<std::int32_t>(Result::CaptureBackendUnavailable);
    }
    return static_cast<std::int32_t>(Result::Ok);
}

std::int32_t OhosInputBridge::getStatus(ReverseControlStatus* status) {
    if (status == nullptr) {
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    if (status->struct_size != sizeof(ReverseControlStatus)) {
        return static_cast<std::int32_t>(Result::InvalidArgument);
    }
    std::scoped_lock lock(sendLock_);
    status->api_version = ApiVersion;
    status->state = static_cast<std::int32_t>(state_);
    const std::wstring errorCodeW = text::utf8_to_wide(lastErrorCode_);
    const std::wstring errorMessageW = text::utf8_to_wide(lastErrorMessage_);
    const auto ecLen = std::min(errorCodeW.size(), static_cast<std::size_t>(63));
    std::copy_n(errorCodeW.begin(), ecLen, status->lastErrorCode);
    status->lastErrorCode[ecLen] = L'\0';
    const auto emLen = std::min(errorMessageW.size(), static_cast<std::size_t>(191));
    std::copy_n(errorMessageW.begin(), emLen, status->lastErrorMessage);
    status->lastErrorMessage[emLen] = L'\0';
    return static_cast<std::int32_t>(Result::Ok);
}

void OhosInputBridge::releaseAllContacts() {
    if (activeTouchContacts_.empty()) return;
    for (auto pointerId : activeTouchContacts_) {
        TouchPoint pt{};
        pt.pointerId = pointerId;
        std::strcpy(pt.action, "up");
        pt.normalizedX = 0.0f;
        pt.normalizedY = 0.0f;
        const auto frame = hidMessage_.formatTouchBatch(&pt, 1, generation_, ++seq_);
        if (tunnel_) tunnel_->sendHidMessage(frame);
    }
    activeTouchContacts_.clear();
}

void OhosInputBridge::releaseAllKeys() {
    if (pressedKeys_.empty()) return;
    const auto frame = hidMessage_.formatKeyboardBatch(nullptr, 0, 1, generation_, ++seq_);
    if (tunnel_) tunnel_->sendHidMessage(frame);
    pressedKeys_.clear();
}

void OhosInputBridge::releaseAllButtons() {
    if (pressedButtons_.empty()) return;
    for (auto buttonKey : pressedButtons_) {
        const std::uint16_t usagePage = (buttonKey >> 8) & 0xFF;
        const std::uint16_t usageCode = buttonKey & 0xFF;
        const auto frame = hidMessage_.formatButtonEvent(usagePage, usageCode, "canceled",
            generation_, ++seq_);
        if (tunnel_) tunnel_->sendHidMessage(frame);
    }
    pressedButtons_.clear();
}

} // namespace iPhoneMirror::ohos