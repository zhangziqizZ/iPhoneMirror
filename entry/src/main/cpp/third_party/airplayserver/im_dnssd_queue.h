// SPDX-License-Identifier: GPL-3.0-only
//
// im_dnssd_queue.h —— DNS-SD 注册「待办队列」的对外接口（鸿蒙专有新增）
//
// 为什么是队列而不是同步回调：
//   AirPlay 库启动时会同步调用 dnssd_register_raop()/dnssd_register_airplay()，
//   期望立刻拿到结果；而鸿蒙 @ohos.net.mdns 的 addLocalService() 是 **异步
//   Promise**，同步 NAPI 上下文里没法 await 它。所以这里把「要广播什么」
//   排成队，由 ArkTS 侧的事件循环取走、真正广播、再回报结果。
//
// 状态语义（遵守本工程"不许假成功"纪律）：
//   * 入队成功只代表"已提交"，不代表"已在网上广播"；
//   * 只有 ArkTS 调 im_dnssd_queue_report(id, ok=1) 之后才算 registered；
//   * 广播失败时 ok=0 并带 reason，计入 failed 且写入 last_error，
//     UI 必须能把这个失败显示出来。

#ifndef IM_DNSSD_QUEUE_H
#define IM_DNSSD_QUEUE_H

#ifdef __cplusplus
extern "C" {
#endif

#define IM_DNSSD_NAME_MAX   256
#define IM_DNSSD_TYPE_MAX    64
#define IM_DNSSD_TXT_MAX   1024
#define IM_DNSSD_REASON_MAX 256

typedef struct im_dnssd_service_s {
    int id;                              // 0 表示无效；>0 唯一自增
    char name[IM_DNSSD_NAME_MAX];        // 服务实例名（RAOP 为 "<hwaddr>@<name>"）
    char type[IM_DNSSD_TYPE_MAX];        // "_raop._tcp" / "_airplay._tcp"
    unsigned short port;
    unsigned char txt[IM_DNSSD_TXT_MAX]; // 已编码好的 TXT 记录（长度前缀串）
    unsigned int txt_length;
} im_dnssd_service_t;

// 入队一个待广播服务。成功返回新 id（>0），失败返回 0。
int im_dnssd_queue_push(const char *name, const char *type,
    unsigned short port, const unsigned char *txt, unsigned int txt_length);

// 入队一个待注销的服务 id。成功返回 1。
int im_dnssd_queue_push_removal(int id);

// 取出一个待广播服务。取到返回 1 并填充 out，队列空返回 0。
// 注意：原生响应器接管（im_dnssd_queue_set_native_backend(1)）后本函数恒返回 0，
// 因为它只服务于 ArkTS 的 @ohos.net.mdns 回退路径。
int im_dnssd_queue_take_service(im_dnssd_service_t *out);

// 取出一个待注销 id。取到返回 1，队列空返回 0。同样受 native backend 开关影响。
int im_dnssd_queue_take_removal(int *id_out);

// ─────────────── 原生 mDNS 响应器专用（不受上面开关影响） ───────────────
// ohos/OhosMdnsResponder.cpp 启动后成为队列的唯一消费者，用这两个函数取待办。
int im_dnssd_queue_take_service_internal(im_dnssd_service_t *out);
int im_dnssd_queue_take_removal_internal(int *id_out);

// 切换消费者：1 = 原生响应器接管（ArkTS 侧 take_* 返回空），0 = 交给 ArkTS。
// 实测 @ohos.net.mdns 在部分设备（鸿蒙 PC / 2in1）上不真的把记录发到网上，
// 因此只要原生响应器能绑上 5353，就由它做广播。
void im_dnssd_queue_set_native_backend(int enabled);
int im_dnssd_queue_native_backend(void);

// ArkTS 回报广播结果。ok=1 成功；ok=0 失败（reason 可为 NULL）。
void im_dnssd_queue_report(int id, int ok, const char *reason);

// 统计：pending=待广播，registered=已确认广播，failed=广播失败，
// pending_removal=待注销。任一出参可为 NULL。
void im_dnssd_queue_stats(int *pending, int *registered, int *failed,
    int *pending_removal);

// 最近一次失败原因（线程安全返回内部缓冲，调用方不要保存指针）。
const char *im_dnssd_queue_last_error(void);

// 清空全部状态（停止接收端时用）。
void im_dnssd_queue_reset(void);

#ifdef __cplusplus
}
#endif

#endif // IM_DNSSD_QUEUE_H
