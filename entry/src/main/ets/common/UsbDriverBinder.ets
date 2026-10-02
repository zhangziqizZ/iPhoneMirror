// SPDX-License-Identifier: GPL-3.0-only
//
// 把外部设备的驱动扩展「绑」起来 —— 这是鸿蒙驱动模型里客户端必须做的一步。
//
// 为什么必须有它：文档对 DriverExtensionAbility 的说法是
//   「DriverExtensionAbility 可以通过 @ohos.driver.deviceManager 提供的接口**被应用绑定**，
//     并根据应用的请求信息在后台处理相关事务」
// 而 OpenHarmony 侧的生命周期实现里还有一个开关（device.cpp 的 launchOnBind）：
//   launchOnBind = false → 设备接入即自动拉起扩展
//   launchOnBind = true  → **只在有客户端 bind 时才拉起**（懒加载，省资源）
// 也就是说"插入 iPhone 扩展就会起来"这句话**不成立**：真到懒加载路径上，
// 不调 bindDevice 它就永远不会被拉起，而 DDK 只在驱动扩展的生命周期内可用。
//
// 另外，绑定还会返还一个 rpc.RemoteObject —— 那是唯一被允许的"驱动 ↔ 客户端"通道
// （驱动扩展内只能用 DDK API，别的 ArkTS API 可能被裁掉，写文件这种动作不可靠）。
//
// 纪律：绑定是异步的，这里不做"假装已绑定"。阶段与原因都如实记账，由界面显示。
//
// ★ 有一条**必须**写进代码的平台行为（2026-09-19 10:14:58 真机崩溃的教训）：
//   bindDevice 既可能 **同步 throw**，也可能异步 reject —— 官方文档的 d.ts 里写的是
//   `@throws { BusinessError } 22900001 - ExternalDeviceManager service exception.`，
//   官方示例也是用 try 包住整个 bindDevice(...).then(...)：
//     try { deviceManager.bindDevice(id, cb).then(ok, fail) } catch (e) { ... }
//   只写 .catch() 抓不到同步抛的那一路。真机证据：FaultLog 的 HybridStack 里
//   #08/#09 在 libdevicemanager_napi.z.so 内 napi_create_error，#13 直接停在
//   UsbDriverBinder.ets 的**调用行**（不是 .catch），随后 pending exception
//   一路冒到 aboutToAppear ⇒ App 被 RuntimeError 杀掉（进程寿命 1 秒）。
//   所以下面的调用点必须 try/catch，Promise 的 .catch 只是第二道防线。

import { deviceManager } from '@kit.DriverDevelopmentKit';
import { BusinessError } from '@ohos.base';
import { t } from './i18n';

/** Apple 的 USB Vendor ID，与 module.json5 的 metadata 保持一致。 */
const APPLE_VENDOR_ID: number = 0x05AC;

/**
 * 同一个 deviceId 上最多自动重试几次。
 *
 * 为什么要限次：调用方是 2 秒一次的环境刷新，不限次就是每 2 秒一次绑架请求，
 * 日志里只能看见最后一次的结果（错误的 toast/记账会被反复冲掉）。
 * 为什么不是"失败就永久放弃"：22900001 的官方可能原因之一是"服务内部遇到通信
 * 输入输出异常"，即瞬时故障 —— 一次失败就锁死会把偶发问题做成永久问题描述。
 * 设备拔出重插后 deviceId 会变，那时计数自动归零。用户也可以点刷新手动归零。
 */
const MAX_BIND_ATTEMPTS: number = 3;

/** 绑定过程的阶段。字符串而非枚举：界面直接显示，跨文件比较不容易写错。 */
export class DriverBindState {
  /** 'idle' 未尝试 | 'binding' 进行中 | 'bound' 已绑定 | 'failed' 失败 */
  phase: string = 'idle';
  deviceId: number = -1;
  /** 给界面的一句话，任何阶段都非空。 ★ 注意：它是**会被下一次结果覆盖**的。 */
  summary: string = '尚未尝试绑定外部设备驱动';

  // ── 事件账本（只增不减） ────────────────────────────────────────────────────
  // 为什么要累计，而不是只存"最近一次"：summary 会被下一次结果整句覆盖，我们已经
  // 两次因此看不见关键证据 —— ① 清理结果只闪现一轮就被下一次失败顶掉；② 更要命的
  // 是 2026-09-19 12:09 那次核对发现：**任何一次截图里都没有出现过「已绑定」**，
  // 而"到底成功过没有"恰恰是判断整条链路状态的分水岭。下面这几个计数只增不减，
  // 一次失败冲不掉它们，"成功过 0 次"这种结论从此可以直接从截图读出来。
  /** 累计发起过几次 bindDevice 调用。 */
  bindAttempts: number = 0;
  /** 累计几次 bindDevice 拿到了 remote（= 真正绑定成功）。 */
  bindSuccess: number = 0;
  /** 累计几次收到"设备已断开"回调。 */
  disconnectEvents: number = 0;
  /** 累计发起过几次 unbindDevice 调用。 */
  unbindAttempts: number = 0;
  /** 累计几次解绑拿到了 0（= 确实存在被解开的绑定）。 */
  unbindSuccess: number = 0;
}

let state: DriverBindState = new DriverBindState();

/** 已在这台设备上发起过几次绑定请求（用于限次重试）。 */
let attempts: number = 0;
/** attempts 记的是哪个 deviceId。设备变了就从头计数。 */
let attemptedDeviceId: number = -1;

/**
 * 需要「先解绑再重试」的 deviceId（-1 = 没有待清理的东西）。
 *
 * ★ 2026-09-19 12:09 更正：下面这段"残留绑定"的推理**建立在一条站不住的推断上**，
 *   保留它作为"补救路径"仍然合理，但**不能再把它当成已证实的根因**。
 *
 *   原来的推理是：11:36 截图里同时挂着「驱动扩展已拉起（onConnect @ 10:58:32）」与
 *   「绑定失败 22900001」，于是断定"10:58 那次 bind 成功过、这次被拒 ⇒ 上次的绑定
 *   没被释放"。这条推理错在**前提**：`DriverExtAbility.onConnect()` 的第一件事就是
 *   `record('onConnect')` 落盘，那是**在 bind 完成之前**发生的 —— 只要扩展被拉起并
 *   走到 onConnect，文件里就会留下时间戳，**哪怕这次 bind 最终失败**。所以 onConnect
 *   的时间戳只能证明"扩展在那一刻被拉起过"，**不能证明任何一次 bind 成功过**。
 *   而翻遍 10:58 / 11:36 / 11:55 / 11:57 / 12:09 五次截图，界面上**从来没有出现过
 *   「已绑定」**。这与"bind 从未成功、扩展每次都被拉起后随即失败"完全一致。
 *
 *   至于"用 unbindDevice 的返回值去证真/证伪残留"：**这个实验不成立**。SDK 的
 *   @ohos.driver.deviceManager.d.ts 与官方错误码文档里，unbindDevice 声明的错误码
 *   只有 201 / 401 / 22900001 三个，**没有**任何"不存在绑定关系"的码（那个码
 *   26300003 There is no binding relationship 属于另一个 API：unbindDriverWithDeviceId）。
 *   所以"解绑抛 22900001"这件事对"有没有残留"**零信息量** —— 它既可能是没有绑定，
 *   也可能是服务本身异常。实测结果（解绑同步抛 22900001）因此不能用来证伪。
 *
 *   结论：这是一条**未被证实**的补救路径。保留它是因为"万一真有残留"时它是唯一的
 *   自救手段，但**启动时不再无条件预清理**（那是纯粹基于错误推理加的开销，还把一次
 *   已知会失败的调用塞进每次冷启动），只在真正失败之后清一次，且结果进事件账本。
 */
let pending_cleanup_device_id: number = -1;

/** 供诊断读取：当前是否有待清理的残留绑定（-1 = 没有）。 */
export function usb_driver_pending_cleanup(): number {
  return pending_cleanup_device_id;
}

/**
 * 最近一次清理（解绑）的结果，null 表示还没清理过。
 *
 * ★ 为什么必须把它留下来：SDK 里**没有**"查询绑定状态"的接口（`@ohos.driver.
 *   deviceManager` 只有 queryDevices / bindDevice / unbindDevice，以及两个走
 *   ACCESS_DDK_DRIVERS 的 bindDriverWithDeviceId / unbindDriverWithDeviceId）。
 *   于是 `unbindDevice()` 的返回值**本身就成了一次探测**：
 *     · 返回 0 → 说明**确实存在一个残留绑定**，我们把它解掉了；
 *     · 返回错误 → 说明根本不存在残留绑定（那 22900001 另有成因）。
 *   这个结论是二分真假"残留假说"的唯一硬证据，但它只在清理那一轮出现一下，
 *   紧接着就会被下一轮的绑定失败覆盖掉。11:57 的截图因此只看到"已重试 3 次"，
 *   完全看不出清理是否发生、是否成功。所以在这里存下来，由失败文案一并带出。
 */
let last_cleanup_note: string = '';

// ★ 2026-09-19 12:09 **已删除**"启动预清理"（原 startup_cleanup_done）：
//   它原本的逻辑是"本次运行第一次绑定时先无条件 unbindDevice 一次再 bind"，理由是
//   "上次运行的绑定残留会占着设备"。那条理由依赖的推断已被推翻（见
//   pending_cleanup_device_id 上方的更正），而且它在**每次冷启动**都塞进一次已知会
//   失败的调用（12:09 截图：清理：解绑同步抛出 22900001），等于给现场添了一个
//   无法归因的变量。删掉它，让"启动 → 直接 bind"成为唯一路径，观测才干净。
//   失败后那条清理路径保留（虽然同样基于未证实的推断），因为它是"真有残留"时
//   唯一的自救手段；它的结果会进事件账本，不再只闪现一轮。
//
//   仍然成立的一条**观察**（保留待查，但不下结论）：真机状态文件里始终只有
//   `onConnect`，从未出现过 `onDisconnect`。注意它**不足以**证明"onDisconnect 永远
//   不会被调用" —— 后面的 onConnect 会把前面的 onDisconnect 覆盖掉，这个文件本来就
//   只留最后一次事件。

/**
 * 允许重新尝试绑定 —— 用户在界面上点了刷新就该重新肯认真试一次，
 * 否则上一轮的失败结论会一直挂到下一次连线的 deviceId 变化为止。
 */
export function reset_usb_driver_bind_retry(): void {
  attempts = 0;
  attemptedDeviceId = -1;
}

/** UI 侧读取（每 2 秒的刷新节拍里调，纯读不做事）。 */
export function usb_driver_bind_state(): DriverBindState {
  return state;
}

/**
 * 事件账本的一句话形式（只增不减，不会被任何一次新结果覆盖）。
 *
 * 它回答的是**单看 summary 永远答不了**的那个问题：这条链路上有没有**成功过**。
 * 2026-09-19 12:09 的核对就是被这个问题卡住的 —— 五张截图里一次「已绑定」都没出现，
 * 但"没出现"既可能是"从没成功"，也可能是"成功过又被后续失败覆盖"。
 * bind 成功 0 次 ⇒ 服务侧从来没把这次绑定做完；成功过 ≥1 次 ⇒ 另一回事。
 */
export function usb_driver_ledger_text(): string {
  return `账本：bind 尝试 ${state.bindAttempts} 次 / 成功 ${state.bindSuccess} 次；`
    + `断开回调 ${state.disconnectEvents} 次；`
    + `解绑 ${state.unbindAttempts} 次 / 返回 0 共 ${state.unbindSuccess} 次`;
}

function set_state(phase: string, deviceId: number, summary: string): void {
  state.phase = phase;
  state.deviceId = deviceId;
  state.summary = summary;
}

/**
 * 幂等：binding / bound 两个阶段不会重复发起 bindDevice。
 *
 * 之所以要幂等：调用方是 2 秒一次的环境刷新，不挡一下会连发几十次绑定请求。
 *
 * 失败后**有限重试**（同一台设备最多 MAX_BIND_ATTEMPTS 次）而不是立即放弃：
 * 失败原因各不相同（没有 Apple 设备 / 权限 / 驱动不存在 / 服务瞬时异常），
 * 其中 22900001 官方写明的成因之一是"服务内部遇到通信输入输出异常"，属于瞬时故障。
 * 之所以还要限次：不限次就是每 2 秒刷一次失败原因，用户根本看不见第一次为什么失败。
 * 重插设备会换 deviceId、用户点刷新会调 reset_usb_driver_bind_retry()，两者都清零重来。
 */
export function ensure_usb_driver_bound(): void {
  if (state.phase === 'binding' || state.phase === 'bound') {
    return;
  }

  // 上一轮绑定失败留下了疑似残留绑定：这一轮只做清理，bind 留到下一轮（2 秒后）。
  // 为什么拆成两轮：unbindDevice 是异步的，在本轮里等它返回再 bind 就得引入
  // 回调嵌套；而调用方本来就是 2 秒一次的刷新节拍，分两轮做又清楚又不会卡住 UI。
  if (pending_cleanup_device_id >= 0) {
    const stale: number = pending_cleanup_device_id;
    pending_cleanup_device_id = -1;
    unbind_stale_binding(stale);
    return;
  }

  let devices: Array<Readonly<deviceManager.Device>> = [];
  try {
    devices = deviceManager.queryDevices(deviceManager.BusType.USB);
  } catch (error) {
    const failure: BusinessError = error as BusinessError;
    // 201 = ACCESS_EXTENSIONAL_DEVICE_DRIVER 没授权（normal 级权限，声明即授权）。
    set_state('failed', -1, `枚举外部设备失败（${failure.code}）：${failure.message}`);
    return;
  }

  // 只挑 Apple 设备：我们的驱动扩展只声明了 VID 0x05AC，绑别的设备匹配不到驱动。
  // queryDevices 的声明返回 Device，但 USB 总线上给的实例带 vendorId/productId
  // （d.ts 里的 USBDevice），所以这里按 USBDevice 读。
  let targetId: number = -1;
  let targetNote: string = '';
  for (let i = 0; i < devices.length; i++) {
    const usb: deviceManager.USBDevice = devices[i] as deviceManager.USBDevice;
    if (usb.vendorId !== APPLE_VENDOR_ID) {
      continue;
    }
    targetId = usb.deviceId;
    targetNote = `${usb.description}（PID 0x${usb.productId.toString(16).toUpperCase()}）`;
    break;
  }
  if (targetId < 0) {
    set_state('failed', -1,
      `外部设备管理服务里没有 Apple（0x05AC）设备，共见 ${devices.length} 台`);
    return;
  }

  if (attemptedDeviceId === targetId && attempts >= MAX_BIND_ATTEMPTS) {
    // 同一台设备已经试够 MAX_BIND_ATTEMPTS 次：停下，把原因留在 summary 里。
    // 再往下走只会每 2 秒刷掉一次失败原因，让人看不见第一次到底为什么失败。
    return;
  }
  if (attemptedDeviceId !== targetId) {
    attempts = 0;
    attemptedDeviceId = targetId;
  }
  attempts += 1;
  state.bindAttempts += 1;
  const attemptNo: number = attempts;

  set_state('binding', targetId, `正在绑定外部设备驱动：${targetNote}（第 ${attemptNo} 次）`);

  // try 不能省：见文件头的 2026-09-19 崩溃说明，bindDevice 会同步抛 BusinessError，
  // 那条路径上 Promise 还没生成，后面的 .catch() 根本不会被调用。
  try {
    deviceManager.bindDevice(targetId, (error: BusinessError | undefined, code: number): void => {
      // 设备拔出或驱动被回收时回调。把已绑定状态撤销，让下一轮刷新可以重试。
      //
      // ★ error **可能是 undefined**。这个回调的形参类型是 AsyncCallback<number>
      //   （见 @ohos.driver.deviceManager 里 bindDevice 的声明），而 AsyncCallback 的
      //   约定是"成功时 err 为 undefined"。真实设备的 2026-09-19 09:51:16 crash 就
      //   栽在这里：断开回调以 undefined 进来，下面那行 `${error.message}` 直接抛
      //   TypeError: Cannot read property message of undefined ⇒ App 被 RuntimeError 杀掉。
      //   之前所有"断线/重插"路径之所以没炸，只是因为一次都没走到过。
      state.phase = 'idle';
      state.deviceId = -1;
      state.disconnectEvents += 1;
      // 既然已经断开，重试预算也一并清零：下一次 inserted（哪怕系统给的 deviceId
      // 与上次相同）都应当重新认认真真试一轮。
      attempts = 0;
      attemptedDeviceId = -1;
      if (error === undefined || error === null) {
        state.summary = `外部设备驱动已断开（code=${code}）`;
        return;
      }
      state.summary = `外部设备驱动已断开（code=${code}）：${error.message}`;
    })
      .then((bound: deviceManager.RemoteDeviceDriver): void => {
        // 拿到 remote 才说明驱动扩展真的起来了（onConnect 已返回端点）。
        // 这里只记账，不把 remote 暴露出去：当前一次绑定就够驱动扩展起来，
        // 数据通道仍留在原生侧，等架构确定后再决定要不要走 IPC。
        const hasRemote: boolean = bound.remote !== undefined && bound.remote !== null;
        state.bindSuccess += 1;
        set_state('bound', bound.deviceId,
          `外部设备驱动已绑定（deviceId=${bound.deviceId}，`
          + `${hasRemote ? '已拿到驱动端点' : '未拿到驱动端点'}）`);
      })
      .catch((error: BusinessError): void => {
        // 异步 reject 这条路（常见成因：驱动包没被识别（vid/pid 不匹配）、
        // 扩展 exported=false、或 ACCESS_EXTENSIONAL_DEVICE_DRIVER 没授予）。
        describe_bind_failure(targetId, error, attemptNo, false, devices.length);
      });
  } catch (error) {
    // 同步 throw 这条路。22900001（ExternalDeviceManager service exception）实测就是
    // 从这里出来的 —— 不接住它就一点机会都没有：异常会冒到 aboutToAppear 把进程杀掉。
    describe_bind_failure(targetId, error as BusinessError, attemptNo, true, devices.length);
  }
}

/**
 * 把一次绑定失败写成界面能读的一句话。
 *
 * @param thrown true = 调用点同步抛出；false = Promise 异步 reject。
 *               区分它是为了排障：同一个错误码从这两条路出来的处置不同（同步抛出
 *               通常意味着服务压根没受理这次调用）。
 * @param seenDevices 本次 queryDevices 一共看见几台设备。写进文案是为了区分
 *               "服务里根本没有这台设备"与"设备在、但服务拒绝绑定"这两种失败 ——
 *               11:36 的截图里外部设备管理服务明明报出了 1 台 Apple 设备
 *               （USB&BUS_01&DEV_02&PID_12A8&VID_05AC），所以属于后者。
 */
function describe_bind_failure(deviceId: number, error: BusinessError, attempt: number,
  thrown: boolean, seenDevices: number): void {
  const how: string = thrown ? '同步抛出' : '异步返回';
  const code: number = error.code;
  const note: string = code === 22900001
    ? '（该码的官方处置：确认设备形态是 PC/2in1、busType 合法，必要时重启设备）'
    : '';
  let plan: string;
  if (code === 22900001 && attempt < MAX_BIND_ATTEMPTS) {
    // 每次 bind 前先清一次残留绑定。attempts 到上限后不再排队清理，
    // 否则会变成「解绑→绑定→失败→解绑」的无限循环，把真正的失败原因刷掉。
    pending_cleanup_device_id = deviceId;
    plan = `下一轮先解绑一次再重试（第 ${attempt}/${MAX_BIND_ATTEMPTS} 次）`;
  } else if (attempt < MAX_BIND_ATTEMPTS) {
    plan = `将于下次刷新重试（第 ${attempt}/${MAX_BIND_ATTEMPTS} 次）`;
  } else {
    plan = `已重试 ${MAX_BIND_ATTEMPTS} 次，停止自动重试；重插数据线或点刷新可再试`;
  }
  // 把最近一次清理的结果一并带出来 —— 它是"残留假说"唯一能被证真/证伪的证据，
  // 却只会闪现一轮（下一轮绑定失败就把它顶掉了），不在这里带出就等于没测。
  const cleanup: string = last_cleanup_note.length > 0 ? `；${last_cleanup_note}` : '';
  // deviceId 必须写出来：此前界面只报错误码，看不出我们到底把哪个 id 交给了服务。
  // 若这个 id 是 0 / -1 之类的非法值，服务的"service exception"就有了另一条解释。
  set_state('failed', deviceId,
    `绑定外部设备驱动失败（${how} ${code}，deviceId=${deviceId}）：${error.message}${note}。`
    + `服务里可见 ${seenDevices} 台 USB 设备${cleanup}。${usb_driver_ledger_text()}。${plan}`);
}

/**
 * 清理上一次失败的绑定残留：解绑一次，让设备能被重新 bind。
 *
 * 解绑失败不代表没戏 —— 很可能本来就没有绑定（那说明 22900001 另有成因），
 * 所以这里把两种结果都记成 idle，让下一轮照常去试 bind；原因原样写进 summary，
 * 不掩盖。
 */
function unbind_stale_binding(deviceId: number): void {
  set_state('binding', deviceId, `清理上次残留的驱动绑定（deviceId=${deviceId}），随后重试`);
  state.unbindAttempts += 1;
  // unbindDevice 的 d.ts 同样标了 @throws 22900001，会同步抛，所以 try 不能省。
  try {
    deviceManager.unbindDevice(deviceId)
      .then((code: number): void => {
        // code === 0 ⇒ 真的解掉了一个存在的绑定。**但反过来不成立**：
        // 解绑失败并不能说明"没有残留"，因为 unbindDevice 根本没有表达
        // "不存在绑定关系"的错误码（见 pending_cleanup_device_id 上方的更正）。
        if (code === 0) {
          state.unbindSuccess += 1;
        }
        last_cleanup_note = code === 0
          ? '清理：解绑返回 0（确实存在残留绑定，已解开）'
          : `清理：解绑返回 ${code}（非 0，未按预期解开）`;
        set_state('idle', -1, `已清理残留的驱动绑定（code=${code}），下一轮重新绑定`);
      })
      .catch((error: BusinessError): void => {
        // 解绑失败 ⇒ 很可能压根没有绑定（也可能是有但解不掉）。
        // 两种含义不同，但都指向"残留假说需要另找证据"，如实写出来。
        last_cleanup_note =
          `清理：解绑失败（${error.code}）：${error.message}`;
        set_state('idle', -1,
          `清理残留绑定未成功（${error.code}）：${error.message}；下一轮仍会重新绑定`);
      });
  } catch (error) {
    const failure: BusinessError = error as BusinessError;
    last_cleanup_note =
      `清理：解绑同步抛出（${failure.code}）：${failure.message}`;
    set_state('idle', -1,
      `清理残留绑定同步抛出（${failure.code}）：${failure.message}；下一轮仍会重新绑定`);
  }
}

/** 供诊断用：当前是否已绑定。 */
export function usb_driver_bound(): boolean {
  return state.phase === 'bound';
}

/** 显式解绑。留作后续"让原生侧独占设备"时使用，目前没有调用点。 */
export function unbind_usb_driver(): void {
  if (state.deviceId < 0) {
    return;
  }
  const id: number = state.deviceId;
  // 同样要 try：unbindDevice 的 d.ts 里也是 @throws 22900001，会同步抛。
  try {
    deviceManager.unbindDevice(id)
      .then((code: number): void => {
        set_state('idle', -1, `已解绑外部设备驱动（code=${code}）`);
      })
      .catch((error: BusinessError): void => {
        set_state('failed', id, `解绑外部设备驱动失败（${error.code}）：${error.message}`);
      });
  } catch (error) {
    const failure: BusinessError = error as BusinessError;
    set_state('failed', id, `解绑外部设备驱动失败（同步抛出 ${failure.code}）：${failure.message}`);
  }
}
