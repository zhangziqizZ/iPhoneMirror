#include "OhosHidMessage.h"

#include <cstring>
#include <string>

namespace iPhoneMirror::ohos {

namespace {
constexpr const char* kSchema = "iphoneMirror.touch.v2";
constexpr std::int32_t kProtocolVersion = 2;
constexpr std::int32_t kDigitizerSurfaceMainTouchscreen = 257;
constexpr std::int32_t kKeyboardSurface = 512;
}

std::vector<std::uint8_t> OhosHidMessage::formatTouchBatch(
    const TouchPoint* points, std::uint32_t count,
    std::int64_t generation, std::uint64_t seq) {
    std::string json = "{\"schema\":\"";
    json += kSchema;
    json += "\",\"generation\":";
    json += std::to_string(generation);
    json += ",\"kind\":\"touch_batch\",\"seq\":";
    json += std::to_string(seq);
    json += ",\"timestampNs\":0,\"surface\":";
    json += std::to_string(kDigitizerSurfaceMainTouchscreen);
    json += ",\"protocolVersion\":";
    json += std::to_string(kProtocolVersion);
    json += ",\"points\":[";
    for (std::uint32_t i = 0; i < count; ++i) {
        if (i > 0) json += ",";
        json += "{\"pointerId\":";
        json += std::to_string(points[i].pointerId);
        json += ",\"action\":\"";
        json += points[i].action;
        json += "\",\"normalizedX\":";
        json += std::to_string(points[i].normalizedX);
        json += ",\"normalizedY\":";
        json += std::to_string(points[i].normalizedY);
        json += "}";
    }
    json += "]}";
    return encodeFrame(json);
}

std::vector<std::uint8_t> OhosHidMessage::formatKeyboardBatch(
    const std::uint8_t* usages, std::uint32_t count,
    std::int32_t releaseAll, std::int64_t generation, std::uint64_t seq) {
    std::string json = "{\"schema\":\"";
    json += kSchema;
    json += "\",\"generation\":";
    json += std::to_string(generation);
    json += ",\"kind\":\"keyboard_batch\",\"releaseAll\":";
    json += releaseAll != 0 ? "true" : "false";
    json += ",\"seq\":";
    json += std::to_string(seq);
    json += ",\"timestampNs\":0,\"surface\":";
    json += std::to_string(kKeyboardSurface);
    json += ",\"protocolVersion\":";
    json += std::to_string(kProtocolVersion);
    json += ",\"usages\":[";
    for (std::uint32_t i = 0; i < count; ++i) {
        if (i > 0) json += ",";
        json += std::to_string(static_cast<int>(usages[i]));
    }
    json += "]}";
    return encodeFrame(json);
}

std::vector<std::uint8_t> OhosHidMessage::formatButtonEvent(
    std::uint16_t usagePage, std::uint16_t usageCode,
    const char* state, std::int64_t generation, std::uint64_t seq) {
    std::string json = "{\"schema\":\"";
    json += kSchema;
    json += "\",\"generation\":";
    json += std::to_string(generation);
    json += ",\"kind\":\"button_event\",\"seq\":";
    json += std::to_string(seq);
    json += ",\"timestampNs\":0,\"usagePage\":";
    json += std::to_string(static_cast<int>(usagePage));
    json += ",\"usageCode\":";
    json += std::to_string(static_cast<int>(usageCode));
    json += ",\"state\":\"";
    json += state;
    json += "\"}";
    return encodeFrame(json);
}

std::vector<std::uint8_t> OhosHidMessage::encodeFrame(const std::string& jsonPayload) {
    const std::uint32_t length = static_cast<std::uint32_t>(jsonPayload.size());
    std::vector<std::uint8_t> frame;
    frame.reserve(4 + jsonPayload.size());
    frame.push_back(static_cast<std::uint8_t>((length >> 24) & 0xFF));
    frame.push_back(static_cast<std::uint8_t>((length >> 16) & 0xFF));
    frame.push_back(static_cast<std::uint8_t>((length >> 8) & 0xFF));
    frame.push_back(static_cast<std::uint8_t>(length & 0xFF));
    frame.insert(frame.end(), jsonPayload.begin(), jsonPayload.end());
    return frame;
}

} // namespace iPhoneMirror::ohos