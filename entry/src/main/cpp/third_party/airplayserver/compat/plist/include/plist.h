// SPDX-License-Identifier: LGPL-2.1-or-later
//
// compat/plist/include/plist.h —— vendored 头文件布局的转发头
//
// 原因：AirPlayServer v1.1.2 的协议代码里写的是
//          #include "plist/include/plist.h"
//   这是标准 libplist 的目录布局（<prefix>/include/plist/plist.h）。
//   但本仓库把 libplist 摊平放在了 lib/lib/plist/ 下，没有 include/ 这一层，
//   而且 lib/lib/plist/ 下有两个同名文件：
//     * plist/plist.h（74 行）—— Zach C. 的旧版 plist，不是我们要的
//     * plist/plist/plist.h（686 行，LIBPLIST_H）—— 真正的 libplist 公共头
//
// 做法（遵守纪律：不改动 vendored 代码，只新增文件）：
//   补一个 include/ 层的转发头，指向真正的 libplist 公共头。
//   CMakeLists.txt 里把 ${AP_ROOT}/compat 加进 include 路径即可。

#ifndef IM_COMPAT_PLIST_FORWARDER_H
#define IM_COMPAT_PLIST_FORWARDER_H

#include "lib/lib/plist/plist/plist.h"

#endif
