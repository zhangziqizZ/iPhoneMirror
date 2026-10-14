#pragma once

#include "iPhoneMirror/CoreApi.h"

#include <cstdint>
#include <vector>

namespace iPhoneMirror::ohos {

class OhosHidMessage {
public:
    std::vector<std::uint8_t> formatTouchBatch(
        const TouchPoint* points, std::uint32_t count,
        std::int64_t generation, std::uint64_t seq);
    std::vector<std::uint8_t> formatKeyboardBatch(
        const std::uint8_t* usages, std::uint32_t count,
        std::int32_t releaseAll, std::int64_t generation, std::uint64_t seq);
    std::vector<std::uint8_t> formatButtonEvent(
        std::uint16_t usagePage, std::uint16_t usageCode,
        const char* state, std::int64_t generation, std::uint64_t seq);

private:
    std::vector<std::uint8_t> encodeFrame(const std::string& jsonPayload);
};

} // namespace iPhoneMirror::ohos