// SPDX-License-Identifier: GPL-3.0-only
//
// OhosMdnsResponder.h —— 鸿蒙上自实现的 mDNS / DNS-SD 响应器（新增文件）
//
// ── 为什么必须自己写，而不是用 @ohos.net.mdns ──
// 实测事实（HarmonyOS PC / MatePad Edge，见 .workbuddy/memory/2026-09-16.md）：
//   * 设备上没有常驻 mDNS 守护进程，UDP 5353 可以被独占绑定、组播也发得出去；
//   * 但 ArkTS 的 mdns.addLocalService() 在这台机器上**不把记录发到网上**——
//     局域网抓包抓不到 _airplay._tcp / _raop._tcp，即 iPhone 永远搜不到设备；
//   * 用原始套接字自写响应器（tools/mdns_responder_proto.py 原型）后，
//     iPhone 立刻在「屏幕镜像」里看到了服务名 → 这条路是通的。
//
// 于是把原型逻辑正式落到原生层，取代 @ohos.net.mdns：
//   * 绑定 UDP 5353 + 加入 224.0.0.251；
//   * **运行时**解析本机 IP（绝不写死：DHCP 换租约后写死会把 iPhone 指向别的机器）；
//   * 应答 _airplay._tcp / _raop._tcp 的 PTR / SRV / TXT 与主机名 A 查询；
//   * 周期性主动宣告；停止时发 TTL=0 的 goodbye。
//
// 与协议库的衔接：AirPlay 库启动时会同步调用 dnssd_register_raop/airplay，
// 鸿蒙侧由 third_party/airplayserver/dnssd_ohos.c 把"要广播什么"排进
// im_dnssd_queue.h 的待办队列。本模块启动成功后接管该队列（ArkTS 侧不再消费），
// 真实广播出去之后再用 im_dnssd_queue_report() 回报，UI 的"已广播/广播失败"
// 因此仍是真实状态，不做假成功。

#ifndef IPHONEMIRROR_OHOS_MDNS_RESPONDER_H
#define IPHONEMIRROR_OHOS_MDNS_RESPONDER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 启动响应器：绑定 UDP 5353、加入组播、起工作线程，并接管 DNS-SD 待办队列。
// 返回 0 = 成功；非 0 = 失败（原因见 im_mdns_responder_error()）。
// 失败时调用方应保留 ArkTS 的 @ohos.net.mdns 回退路径（虽然它可能不工作）。
int im_mdns_responder_start(void);

// 停止：给每个已宣告的服务发 TTL=0 的 goodbye，收线程、关套接字，
// 并把 DNS-SD 队列交还给 ArkTS 侧消费。
void im_mdns_responder_stop(void);

// 1 = 响应器正在运行（原生 mDNS 广播生效中）。
// 注意：这里的"运行"指 worker 线程仍在轮询——见 im_mdns_responder_last_tick_ms()。
int im_mdns_responder_is_active(void);

// 最近一次 worker 心跳时间（steady_clock 内部 ms epoch）。UI 层用
// "now - last"判定响应器是否被冻结/卡死，比单一 active bit 强得多。
// 0 = worker 从未进入第一次 poll，或已经退出。两次正常返回之间超过 5s 即报死。
// 指针/数值都不需要释放，调用方只读就行。
std::int64_t im_mdns_responder_last_tick_ms(void);

// 重置一次性的"心跳超时"告警，让下次启动能重新探测。
void im_mdns_responder_clear_health_warning(void);

// 最近一次启动失败原因；没有失败时是空串。指针指向内部缓冲，调用方不要保存。
const char *im_mdns_responder_error(void);

// 当前用于 A 记录的本机 IPv4（空串 = 还没解析出来）。调用方不要保存指针。
const char *im_mdns_responder_local_ip(void);

// 当前用于 SRV 目标的 mDNS 主机名（形如 "iPhoneMirror-ABCDEF.local"）。
const char *im_mdns_responder_hostname(void);

// 已应答的 mDNS 查询条数。iPhone 打开「屏幕镜像」时会来问，
// 计数 > 0 说明"局域网里确实有人来问过我们"，是排查的有力证据。
uint64_t im_mdns_responder_answered_queries(void);

// 本机主网卡 MAC（"AA:BB:CC:DD:EE:FF"）。AirPlay 的 deviceid 与 mDNS 主机名
// 共用这一份来源，避免两处各读一次；读不到返回 -1。
int im_ohos_primary_mac(char *out, unsigned int capacity);

// ── 诊断出口（"已应答 N 次、iPhone 却搜不到"专用）──
//
// 为什么需要它们：本机开着 IP_MULTICAST_LOOP=0，自己发的组播包不回环；而来源为
// 本机的包又会被主动丢弃。两条加在一起，**任何从本机跑的探针都看不见我们出包**，
// 于是"响没响应"无法从外部观测，只能由进程内记账导出。
//
// 判读方式：
//   dropped_self > 0        → 本机探针报的"0 应答"是自家闸门所致，别当成响应器已死
//   announce_sent == 0      → 从来没有成功宣告过（服务没注册上，或被频率熔断掐了）
//   announce_failed > 0     → 宣告 sendto 失败（网卡/路由问题）
//   outbound_iface ≠ Wi-Fi 地址 → 宣告从虚拟网卡出去 ⇒ 典型"已应答却搜不到"

// 被"来源为本机"那道闸丢弃的包数。
uint64_t im_mdns_responder_dropped_self(void);

// 主动宣告 sendto 成功 / 失败的次数。
uint64_t im_mdns_responder_announce_sent(void);
uint64_t im_mdns_responder_announce_failed(void);

// IP_MULTICAST_IF 内核实际生效值（"0.0.0.0" 或空串 = 没生效，内核自行选路）。
// 调用方不要保存指针。
const char *im_mdns_responder_outbound_iface(void);

// 最近一次被应答的查询来源 IP，与该次应答里 A 记录用的 IP。调用方不要保存指针。
const char *im_mdns_responder_last_answer_from(void);
const char *im_mdns_responder_last_answer_ip(void);

// ── "问了什么 / 我们手里有什么"（2026-09-19 第二轮：已应答 4 次仍搜不到）──
//
// 上面那两个字段只能回答"谁问了"，回答不了**"问的是什么"**。而 iPhone 的
// 「屏幕镜像」列表只认 `_airplay._tcp` 的 PTR；它顺手问 `_raop._tcp`（找音频
// 目标）时，我们同样会答，`mdns_answered` 照样往上涨。于是有两种病症状完全一样：
//   a) iPhone 问了 _airplay，我们手里却没有 _airplay 服务（注册环节掉了）；
//   b) iPhone 只问了 _raop，_airplay 的查询压根没到我们这儿（宣告/网络环节掉了）。
// 不把"问了什么"和"手里有什么"摊开，这两种永远分不清。
//
// 判读：
//   query_counts 里 `_airplay` 为 0        → iPhone 从没问过我们 _airplay：
//                                            它根本没看见我们的 _airplay 记录（宣告没出去）
//   有 `_airplay N` 但没有一条"已答"        → 我们手里没有 _airplay 服务（注册掉了）
//   service_list 里没有 `_airplay._tcp`     → 同上，注册环节丢了
//   两者都正常却仍搜不到                     → 问题在应答内容（A 记录/端口/TXT）

// 最近收到的一条查询，形如 "_airplay._tcp.local. PTR ← 192.168.0.109"；
// 无法应答时追加原因。从未收到过时是空串。调用方不要保存指针。
const char *im_mdns_responder_last_query(void);

// 查询按类别计数（收到即计，不看是否答得出来），形如
// "_airplay 3(答 2) / _raop 1(答 1) / 服务枚举 0 / 其他 2"。
// 全 0 = 本次运行一条查询都没收到。调用方不要保存指针。
const char *im_mdns_responder_query_counts(void);

// 当前真正持有、并已宣告出去的服务清单，形如
// "_raop._tcp:43763 (<mac>@名字) · _airplay._tcp:36919 (名字)"。
// 空串 = 一条都没注册上（此时宣告必然无效）。调用方不要保存指针。
const char *im_mdns_responder_service_list(void);

#ifdef __cplusplus
}
#endif

#endif // IPHONEMIRROR_OHOS_MDNS_RESPONDER_H
