// SPDX-License-Identifier: GPL-3.0-only
//
// dnssd_ohos.c —— iPhoneMirror 鸿蒙版：DNS-SD（mDNS）服务注册后端
//
// 背景：
//   上游 AirPlayServer v1.1.2（RPiPlay 血统）的 lib/lib/dnssd.c 在非 Windows 平台
//   直接 #include <dns_sd.h>，即 Apple Bonjour 的 dns_sd API。鸿蒙既没有
//   dns_sd.h，也没有可 dlopen 的 Bonjour 库，因此原文件在鸿蒙上无法编译。
//
// 做法（遵守本工程纪律：vendored 代码不动，平台相关一律新增文件）：
//   * 不编译 vendored 的 lib/lib/dnssd.c（见 CMakeLists.txt 的排除说明）；
//   * 本文件实现 dnssd.h 暴露的全部 6 个函数，字段取值与 TXT 条目逐条对齐
//     原版 dnssd.c，保证对端 iOS 看到的服务声明与原版一致；
//   * DNS-SD TXT 记录用自己的极小编码器（长度前缀 key[=value] 串），
//     不依赖任何 dns_sd 符号；
//   * 真正的「把服务广播出去」交给鸿蒙 ArkTS 的 @ohos.net.mdns。因为
//     addLocalService() 是异步 Promise 而库这里是同步调用，二者通过
//     im_dnssd_queue.h 的待办队列衔接：本文件只负责"排队"，ArkTS 负责
//     "广播 + 回报"，回报失败会记进 last_error 与 failed 计数。

#include "dnssd.h"

#include "dnssdint.h"
#include "global.h"
#include "utils.h"

#include "im_dnssd_queue.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ─────────────────────────── TXT 记录编码 ───────────────────────────
// DNS-SD TXT = 一串 [1 字节长度][key 或 key=value]，总长 ≤ 65535，
// 单条 ≤ 255。这里上限取 1024，AirPlay 的字段量远用不到。

#define IM_TXT_CAPACITY IM_DNSSD_TXT_MAX

typedef struct im_txt_record_s {
    unsigned char buffer[IM_TXT_CAPACITY];
    unsigned int length;
} im_txt_record_t;

static void im_txt_init(im_txt_record_t *record) {
    record->length = 0;
}

static int im_txt_set(im_txt_record_t *record, const char *key, const char *value) {
    const size_t key_length = strlen(key);
    const size_t value_length = (value != NULL) ? strlen(value) : 0;
    // value == NULL 时只写 key；否则写 "key=value"。
    //
    // 数据长度 = key + ("=" + value)。RFC 6763 规定 length byte **只数数据本身**，
    // 不包含 length byte 自己：
    //   <len><data...>，data 共 len 字节
    // 之前这里算的是 `entry = 1 + data_length`（含 length byte），然后直接把
    // entry 当 length byte 写出去 —— 每个 entry 在 wire 上**都比真实数据多 1**，
    // iPhone (RFC-correct) 解析时把下一项的 length byte 当成本项最后一个字符，
    // 整条 TXT 链式错位 ⇒ model/deviceid/features 全是乱码 ⇒ iPhone 不知道我们
    // 是 AirPlay 接收端 ⇒ 不会列进「屏幕镜像」。**这是 09-19 排查「已应答 N 次、
    // iPhone 仍搜不到」的真正根因** —— 不是 `model` 字段、不是响应结构，是 TXT
    // 编码从一开始就坏着。
    //
    // 改：length byte = data_length（RFC 正确），总占位 = data_length + 1。
    const size_t data_length = key_length + ((value != NULL) ? (1 + value_length) : 0);
    const size_t total = 1 + data_length;
    if (data_length > 255) return -1;
    if (record->length + total > IM_TXT_CAPACITY) return -1;

    unsigned char *cursor = record->buffer + record->length;
    *cursor++ = (unsigned char)data_length;
    memcpy(cursor, key, key_length);
    cursor += key_length;
    if (value != NULL) {
        *cursor++ = '=';
        memcpy(cursor, value, value_length);
    }
    record->length += (unsigned int)total;
    return 0;
}

// ─────────────────────────── 待办队列（对外见 im_dnssd_queue.h） ───────────────────────────

#define IM_DNSSD_MAX_SERVICES 8
#define IM_DNSSD_REMOVAL_CAPACITY (IM_DNSSD_MAX_SERVICES * 2)

typedef enum im_slot_state_e {
    IM_SLOT_FREE = 0,       // 未使用
    IM_SLOT_PENDING = 1,    // 待 ArkTS 取走广播
    IM_SLOT_PUBLISHING = 2, // 已取走，等回报
    IM_SLOT_REGISTERED = 3, // 已确认在网上广播
    IM_SLOT_FAILED = 4,     // 广播失败
    IM_SLOT_REMOVING = 5    // 待 ArkTS 取走注销
} im_slot_state_t;

typedef struct im_slot_s {
    int id;
    im_slot_state_t state;
    im_dnssd_service_t service;
    char reason[IM_DNSSD_REASON_MAX];
} im_slot_t;

static im_slot_t g_slots[IM_DNSSD_MAX_SERVICES];
static int g_removal[IM_DNSSD_REMOVAL_CAPACITY];
static int g_removal_head = 0;
static int g_removal_tail = 0;
static int g_next_id = 1;
static char g_last_error[IM_DNSSD_REASON_MAX];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
// 1 = 原生 mDNS 响应器（OhosMdnsResponder）已接管队列，成为唯一消费者；
// ArkTS 侧的 im_dnssd_queue_take_service/take_removal 此时恒返回 0，不再抢待办。
static int g_native_backend = 0;

static im_slot_t *im_slot_find(int id) {
    for (int i = 0; i < IM_DNSSD_MAX_SERVICES; ++i) {
        if (g_slots[i].state != IM_SLOT_FREE && g_slots[i].id == id) {
            return &g_slots[i];
        }
    }
    return NULL;
}

static void im_removal_push_locked(int id) {
    int next = (g_removal_tail + 1) % IM_DNSSD_REMOVAL_CAPACITY;
    if (next == g_removal_head) return; // 满了就丢弃：注销失败不会谎报成功，只是不再重试
    g_removal[g_removal_tail] = id;
    g_removal_tail = next;
}

int im_dnssd_queue_push(const char *name, const char *type,
    unsigned short port, const unsigned char *txt, unsigned int txt_length) {
    if (name == NULL || type == NULL) return 0;
    if (txt_length > IM_DNSSD_TXT_MAX) return 0;

    pthread_mutex_lock(&g_lock);
    im_slot_t *slot = NULL;
    for (int i = 0; i < IM_DNSSD_MAX_SERVICES; ++i) {
        if (g_slots[i].state == IM_SLOT_FREE) {
            slot = &g_slots[i];
            break;
        }
    }
    if (slot == NULL) {
        pthread_mutex_unlock(&g_lock);
        snprintf(g_last_error, sizeof(g_last_error), "mDNS 队列已满（上限 %d）",
            IM_DNSSD_MAX_SERVICES);
        return 0;
    }

    memset(slot, 0, sizeof(*slot));
    slot->id = g_next_id++;
    if (g_next_id <= 0) g_next_id = 1;
    slot->state = IM_SLOT_PENDING;
    snprintf(slot->service.name, sizeof(slot->service.name), "%s", name);
    snprintf(slot->service.type, sizeof(slot->service.type), "%s", type);
    slot->service.port = port;
    slot->service.txt_length = txt_length;
    if (txt != NULL && txt_length > 0) {
        memcpy(slot->service.txt, txt, txt_length);
    }
    slot->service.id = slot->id;
    const int id = slot->id;
    pthread_mutex_unlock(&g_lock);
    return id;
}

int im_dnssd_queue_push_removal(int id) {
    if (id <= 0) return 0;
    pthread_mutex_lock(&g_lock);
    im_slot_t *slot = im_slot_find(id);
    if (slot == NULL) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    slot->state = IM_SLOT_REMOVING;
    im_removal_push_locked(id);
    pthread_mutex_unlock(&g_lock);
    return 1;
}

int im_dnssd_queue_take_service(im_dnssd_service_t *out) {
    if (out == NULL) return 0;
    pthread_mutex_lock(&g_lock);
    if (g_native_backend) {  // 原生响应器接管后，ArkTS 回退路径不再消费
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    for (int i = 0; i < IM_DNSSD_MAX_SERVICES; ++i) {
        if (g_slots[i].state == IM_SLOT_PENDING) {
            g_slots[i].state = IM_SLOT_PUBLISHING;
            memcpy(out, &g_slots[i].service, sizeof(*out));
            pthread_mutex_unlock(&g_lock);
            return 1;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return 0;
}

int im_dnssd_queue_take_removal(int *id_out) {
    if (id_out == NULL) return 0;
    pthread_mutex_lock(&g_lock);
    if (g_native_backend) {  // 同上：原生响应器接管后返回空
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    if (g_removal_head == g_removal_tail) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    const int id = g_removal[g_removal_head];
    g_removal_head = (g_removal_head + 1) % IM_DNSSD_REMOVAL_CAPACITY;
    im_slot_t *slot = im_slot_find(id);
    if (slot != NULL) {
        slot->state = IM_SLOT_FREE;
    }
    pthread_mutex_unlock(&g_lock);
    *id_out = id;
    return 1;
}

// ─────────────── 原生 mDNS 响应器专用（不受 backend 开关影响） ───────────────
// 下面两个 _internal 函数与本文件上面的 take_service/take_removal 逻辑一致，
// 但它们**忽略** g_native_backend —— 因为调用者 OhosMdnsResponder 本身就是
// 那个"原生_backend"，它必须能绕过开关消费自己的待办。

int im_dnssd_queue_take_service_internal(im_dnssd_service_t *out) {
    if (out == NULL) return 0;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < IM_DNSSD_MAX_SERVICES; ++i) {
        if (g_slots[i].state == IM_SLOT_PENDING) {
            g_slots[i].state = IM_SLOT_PUBLISHING;
            memcpy(out, &g_slots[i].service, sizeof(*out));
            pthread_mutex_unlock(&g_lock);
            return 1;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return 0;
}

int im_dnssd_queue_take_removal_internal(int *id_out) {
    if (id_out == NULL) return 0;
    pthread_mutex_lock(&g_lock);
    if (g_removal_head == g_removal_tail) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    const int id = g_removal[g_removal_head];
    g_removal_head = (g_removal_head + 1) % IM_DNSSD_REMOVAL_CAPACITY;
    im_slot_t *slot = im_slot_find(id);
    if (slot != NULL) {
        slot->state = IM_SLOT_FREE;
    }
    pthread_mutex_unlock(&g_lock);
    *id_out = id;
    return 1;
}

void im_dnssd_queue_set_native_backend(int enabled) {
    pthread_mutex_lock(&g_lock);
    g_native_backend = enabled ? 1 : 0;
    pthread_mutex_unlock(&g_lock);
}

int im_dnssd_queue_native_backend(void) {
    pthread_mutex_lock(&g_lock);
    const int value = g_native_backend;
    pthread_mutex_unlock(&g_lock);
    return value;
}

void im_dnssd_queue_report(int id, int ok, const char *reason) {
    pthread_mutex_lock(&g_lock);
    im_slot_t *slot = im_slot_find(id);
    if (slot == NULL) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    if (slot->state == IM_SLOT_REMOVING || slot->state == IM_SLOT_FREE) {
        // 已经（或正在）注销，晚到的结果不影响当前状态。
        pthread_mutex_unlock(&g_lock);
        return;
    }
    if (ok) {
        slot->state = IM_SLOT_REGISTERED;
        slot->reason[0] = '\0';
    } else {
        slot->state = IM_SLOT_FAILED;
        snprintf(slot->reason, sizeof(slot->reason), "%s",
            (reason != NULL && reason[0] != '\0') ? reason : "未知原因");
        snprintf(g_last_error, sizeof(g_last_error), "mDNS 广播失败（%s）：%s",
            slot->service.type, slot->reason);
    }
    pthread_mutex_unlock(&g_lock);
}

void im_dnssd_queue_stats(int *pending, int *registered, int *failed,
    int *pending_removal) {
    int p = 0, r = 0, f = 0;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < IM_DNSSD_MAX_SERVICES; ++i) {
        switch (g_slots[i].state) {
            case IM_SLOT_PENDING:
            case IM_SLOT_PUBLISHING:
                ++p;
                break;
            case IM_SLOT_REGISTERED:
                ++r;
                break;
            case IM_SLOT_FAILED:
                ++f;
                break;
            default:
                break;
        }
    }
    int removal = (g_removal_tail - g_removal_head + IM_DNSSD_REMOVAL_CAPACITY) %
        IM_DNSSD_REMOVAL_CAPACITY;
    pthread_mutex_unlock(&g_lock);
    if (pending != NULL) *pending = p;
    if (registered != NULL) *registered = r;
    if (failed != NULL) *failed = f;
    if (pending_removal != NULL) *pending_removal = removal;
}

const char *im_dnssd_queue_last_error(void) {
    return g_last_error;
}

void im_dnssd_queue_reset(void) {
    pthread_mutex_lock(&g_lock);
    memset(g_slots, 0, sizeof(g_slots));
    g_removal_head = 0;
    g_removal_tail = 0;
    g_last_error[0] = '\0';
    pthread_mutex_unlock(&g_lock);
}

// ─────────────────────────── dnssd 实现 ───────────────────────────

struct dnssd_s {
    int raop_id;
    int airplay_id;
};

dnssd_t *
dnssd_init(int *error) {
    dnssd_t *dnssd = (dnssd_t *)calloc(1, sizeof(dnssd_t));
    if (dnssd == NULL) {
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }
    if (error) *error = DNSSD_ERROR_NOERROR;
    return dnssd;
}

int
dnssd_register_raop(dnssd_t *dnssd, const char *name, unsigned short port,
    const char *hwaddr, int hwaddrlen, int password) {
    char servname[256];
    char deviceid[3 * MAX_HWADDR_LEN];
    char features[32];
    im_txt_record_t txt;

    assert(dnssd);
    assert(name);
    assert(hwaddr);

    if (utils_hwaddr_raop(deviceid, sizeof(deviceid), hwaddr, hwaddrlen) < 0) {
        return -1;
    }
    // 原版把服务名写成 "<hwaddr>@<name>"。
    if (snprintf(servname, sizeof(servname), "%s@%s", deviceid, name) < 0) {
        return -1;
    }
    snprintf(features, sizeof(features), "0x%X,0x%X",
        GLOBAL_FEATURES_1, GLOBAL_FEATURES_2);

    im_txt_init(&txt);
    im_txt_set(&txt, "txtvers", RAOP_TXTVERS);
    im_txt_set(&txt, "ch", RAOP_CH);
    im_txt_set(&txt, "cn", RAOP_CN);
    im_txt_set(&txt, "et", RAOP_ET);
    im_txt_set(&txt, "sv", RAOP_SV);
    im_txt_set(&txt, "da", RAOP_DA);
    im_txt_set(&txt, "sr", RAOP_SR);
    im_txt_set(&txt, "ss", RAOP_SS);
    im_txt_set(&txt, "pw", password ? "true" : "false");
    im_txt_set(&txt, "vn", RAOP_VN);
    im_txt_set(&txt, "tp", RAOP_TP);
    im_txt_set(&txt, "md", RAOP_MD);
    im_txt_set(&txt, "vs", GLOBAL_VERSION);
    im_txt_set(&txt, "sm", RAOP_SM);
    im_txt_set(&txt, "ek", RAOP_EK);
    im_txt_set(&txt, "sf", RAOP_SF);
    im_txt_set(&txt, "ft", features);
    im_txt_set(&txt, "am", GLOBAL_MODEL);

    const int id = im_dnssd_queue_push(servname, "_raop._tcp", port,
        txt.buffer, txt.length);
    if (id <= 0) {
        return -1;
    }
    dnssd->raop_id = id;
    return 1;
}

int
dnssd_register_airplay(dnssd_t *dnssd, const char *name, unsigned short port,
    const char *hwaddr, int hwaddrlen) {
    char deviceid[3 * MAX_HWADDR_LEN];
    char features[32];
    im_txt_record_t txt;

    assert(dnssd);
    assert(name);
    assert(hwaddr);

    if (utils_hwaddr_airplay(deviceid, sizeof(deviceid), hwaddr, hwaddrlen) < 0) {
        return -1;
    }
    snprintf(features, sizeof(features), "0x%X,0x%X",
        GLOBAL_FEATURES_1, GLOBAL_FEATURES_2);

    im_txt_init(&txt);
    im_txt_set(&txt, "srcvers", GLOBAL_VERSION);
    im_txt_set(&txt, "deviceid", deviceid);
    im_txt_set(&txt, "features", features);
    im_txt_set(&txt, "model", GLOBAL_MODEL);
    im_txt_set(&txt, "flags", RAOP_SF);
    im_txt_set(&txt, "vv", RAOP_VV);

    const int id = im_dnssd_queue_push(name, "_airplay._tcp", port,
        txt.buffer, txt.length);
    if (id <= 0) {
        return -1;
    }
    dnssd->airplay_id = id;
    return 0;
}

void
dnssd_unregister_raop(dnssd_t *dnssd) {
    assert(dnssd);
    if (dnssd->raop_id > 0) {
        im_dnssd_queue_push_removal(dnssd->raop_id);
    }
    dnssd->raop_id = 0;
}

void
dnssd_unregister_airplay(dnssd_t *dnssd) {
    assert(dnssd);
    if (dnssd->airplay_id > 0) {
        im_dnssd_queue_push_removal(dnssd->airplay_id);
    }
    dnssd->airplay_id = 0;
}

void
dnssd_destroy(dnssd_t *dnssd) {
    if (dnssd == NULL) return;
    dnssd_unregister_raop(dnssd);
    dnssd_unregister_airplay(dnssd);
    free(dnssd);
}
