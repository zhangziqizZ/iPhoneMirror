#ifndef GLOBAL_H
#define GLOBAL_H

/* Mirror/audio receiver capabilities. Direct AirPlay video and HLS are not
 * advertised because this project does not implement URL-based playback. */
#define GLOBAL_FEATURES_1 0x5A7FFEE6U
#define GLOBAL_FEATURES_2 0x00000000U
/* model 字段：iOS 用它选择 AirPlay 协议栈分支。
 *
 * 09-19 更正（基于 15:29 真机截图）：
 *   之前 09-18 的注释（"AppleTV14,1 已被原型验证可显示"）是不严谨的——
 *   原型 `tools/mdns_responder_proto.py` 是个"只应答不服务"的占位进程
 *   （端口 5000/7000 没人监听），iPhone 在 mDNS 浏览列表里能看到它，但
 *   一旦走到"是否能列出到屏幕镜像"的协议栈判定阶段，原型从来没走到过：
 *   iPhone 是用 model 字段决定走 APv1 还是 APv2/FairPlay：
 *
 *     AppleTV2,1  → APv1 接收端路径（无 FairPlay）→ 我们的 vendored RPiPlay 协议栈走这条
 *     AppleTV14,1 → APv2 / FairPlay 路径       → 我们的协议栈不能完成，iPhone 收下应答但**不显示**
 *
 *   15:29 截图确诊症状：iPhone 已应答 4 次、未应答明细全是无关 iOS 探测、
 *   「最近被应答的查询来自 192.168.0.109（回 A 记录=192.168.0.111）」→
 *   iOS 完整收到并解析了我们的 PTR/SRV/TXT/A，但就是不显示设备。**这正是
 *   iOS 走 APv2/FairPlay 分支失败的典型现象**。
 *
 *   RPiPlay/UxPlay 部署文档里所有可被 iPhone 列出的非官方接收端都用
 *   "AppleTV2,1"。改为它，让 iOS 走我们能完成的协议路径。
 */
#define GLOBAL_MODEL    "AppleTV2,1"
#define GLOBAL_VERSION  "845.5.1"

#define MAX_HWADDR_LEN 6

#endif
