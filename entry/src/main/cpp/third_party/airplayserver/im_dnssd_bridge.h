// SPDX-License-Identifier: GPL-3.0-only
//
// im_dnssd_bridge.h —— dnssd_ohos.c 与鸿蒙 ArkTS 侧的桥接声明
//
// 鸿蒙没有 Apple Bonjour（dns_sd），mDNS 服务注册只能走 @ohos.net.mdns，
// 而那套 API 只在 ArkTS 层提供。所以由 NAPI 层实现下面两个函数并注入：
// 原生侧负责组 TXT 记录、ArkTS 侧负责真正把 _raop._tcp / _airplay._tcp
// 广播出去。
//
// 约定：
//   * 注入前，dnssd_register_raop / dnssd_register_airplay 一律返回失败，
//     绝不上报"已注册"（本项目不许假成功）。
//   * register 返回 0 表示成功，非 0 表示失败；成功时通过 handle_out
//     回传一个 ArkTS 侧的不透明句柄（由桥接实现自行管理生命周期）。
//   * unregister 传入 register 回传的句柄；允许传 NULL（实现应忽略）。

#ifndef IM_DNSSD_BRIDGE_H
#define IM_DNSSD_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 注册一个 mDNS 服务。成功返回 0，失败返回非 0。 */
typedef int (*im_mdns_register_fn)(const char *name, const char *type,
    unsigned short port, const unsigned char *txt, unsigned int txt_length,
    void **handle_out);

/** 注销之前注册的服务。 */
typedef void (*im_mdns_unregister_fn)(void *handle);

/**
 * 注入 mDNS 桥接实现。由 NAPI 初始化时调用一次；传 NULL 表示撤销。
 */
void im_dnssd_set_bridge(im_mdns_register_fn register_fn,
    im_mdns_unregister_fn unregister_fn);

#ifdef __cplusplus
}
#endif

#endif // IM_DNSSD_BRIDGE_H
