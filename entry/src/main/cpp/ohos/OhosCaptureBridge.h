// SPDX-License-Identifier: GPL-3.0-only
//
// 采集侧与预览侧之间的内部桥。
//
// 与上游 LinuxCaptureBridge.h 完全同构（那边叫 linux_bridge，这里叫 ohos_bridge），
// 保留同样的两条约束：
//  1) 两侧各占一个翻译单元：采集侧拥有会话，预览侧拥有渲染器，互不 include 对方；
//  2) 传出的是**帧**而不是会话指针——会话指针只在采集锁持有期间有效，把裸指针
//     递出去等于给并发 im_stop_capture 留一个 use-after-free。

#pragma once

#include "Media/VideoFormats.h"

#include <memory>

namespace iPhoneMirror::ohos_bridge {

// 没有会话在跑、或还没有帧到达时返回 nullptr。
[[nodiscard]] std::shared_ptr<const media::DecodedFrame> latest_render_frame();

} // namespace iPhoneMirror::ohos_bridge
