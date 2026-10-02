// Index.d.ts —— libim_core NAPI 模块的类型声明（ArkTS 侧 import 用）。
//
// 与 entry/src/main/cpp/napi_bridge.cpp 的 napi_property_descriptor 表一一对应，
// 也与 CoreApi.h 的 C ABI 语义一致：返回 number 的都是 Result 枚举
// （0 = Ok，负数见下），不是布尔。
//
// Result 枚举（CoreApi.h）：
//      0 Ok                      -1 InvalidArgument
//     -2 NotInitialized          -3 BufferTooSmall
//     -4 TransportUnavailable    -5 ProtocolError
//     -6 DeviceNotFound          -7 CaptureBackendUnavailable
//     -8 SessionAlreadyExists    -9 DriverSafetyBlocked
//    -10 UsbConfigurationNotReady
//    -11 SessionTeardownFailed  -12 UsbConfigurationRestoreWarning
//   -100 InternalError

export const initialize: () => number;
export const shutdown: () => void;
export const apiVersion: () => number;

export interface DeviceInfo {
  udid: string;
  name: string;
  productType: string;
  osVersion: string;
  // ConnectionState：0 Offline、1 Usb、2 Network（见 CoreApi.h）
  state: number;
  connectionType: string;
  status: string;
  deviceId: number;
  muxPort: number;
  usbConnected: number;
}

// 失败时返回空数组；失败原因由 lastError() 给出（C ABI 已写好 last_error）。
// 这样 ArkTS 侧不必处理联合返回类型。
export const refreshDevices: () => DeviceInfo[];

export const startCapture: (udid: string) => number;

// ── 有线（USB）链路的采集参数 ───────────────────────────────────────────────
// 逐字对应 CoreApi.h 的 CaptureOptions：reserved[0]/[1] = 高级模式的自定义 HPD1
// 尺寸，reserved[2] = 有线投屏模式（0 演示 / 1 AirPlay / 2 爱思），
// reserved[3] = 解码器偏好（0 自动 / 1 硬件优先 / 2 软件兼容），
// reserved[4] = 色彩输出（0 自动 / 1 SDR / 2 偏好 HDR）。
// 这些字段没有单独的 setter，只能在开始采集时一次性带上 ⇒ 有线投屏协议、
// 解码器偏好、色彩偏好三者必须走这条入口才生效。
export interface StartCaptureOptions {
  requestedWidth: number;       // 本地渲染上限；与 requestedHeight 同时为 0 = 不限制
  requestedHeight: number;
  targetFps: number;            // 本地渲染帧率上限（不改变来源帧率）
  playAudio: number;            // 1 = 在本机播放声音
  audioVolume: number;          // 线性增益 [0,1]
  usbWidth: number;             // 高级模式自定义 HPD1 尺寸，0 = 不使用
  usbHeight: number;
  usbProjectionMode: number;
  decoderPreference: number;
  colorOutputPreference: number;
}

// 与 startCapture(udid) 的区别：这条会**整份替换** Core 里的采集偏好
// （CoreApi.cpp:983 的 preferences_from_options），所以调用方必须把当前所有
// 设置都带上；只带一部分会把没带的字段重置成 0。返回 Result 码。
export const startCaptureWithOptions: (
  udid: string,
  options: StartCaptureOptions
) => number;

export const stopCapture: () => number;

export interface CaptureStatus {
  // CaptureState：0 Idle、1 ActivatingUsb、2 WaitingForDevice、3 Handshaking、
  // 4 Streaming、5 Stopping、6 Stopped、7 Error。
  // 状态查询自身失败时为 -1（不会伪造成 Idle）。
  state: number;
  width: number;
  height: number;
  fps: number;
  latencyMs: number;
  videoFrames: number;
  audioPackets: number;
  message: string;
}

export const getCaptureStatus: () => CaptureStatus;

// surfaceId 由 XComponentController.getXComponentSurfaceId() 取得的字符串传入。
export const attachPreview: (surfaceId: string) => number;
export const detachPreview: () => void;
// 工具条「刷新画面」。返回真实结果码：0 = Ok，非 0 = 尚未挂载预览 surface（原因取 lastError()）。
export const forcePreviewRefresh: () => number;

export const setAudioEnabled: (enabled: boolean) => number;
export const setAudioVolume: (volume: number) => number;

export const lastError: () => string;

// 有线（USB）链路最近几步的原话（认领接口 / 厂商 0x52 请求 / 重枚举 / 端点），
// 按时间顺序以 " | " 拼接。没有记录时返回空串。
// 存在的原因：Core 的日志落在应用沙箱里，进程外读不到、用户也打不开；
// 有线采集失败时，这串记录是屏幕上唯一能说明"卡在哪一步"的东西。
export const usbDiagnostics: () => string;

// 把原生诊断日志重定向到显式路径（通常应是应用沙箱 filesDir/iPhoneMirror/Logs/startup.log）。
// 原生默认写系统 temp 目录，而 ArkTS 因沙箱隔离读不到，导致「实时日志」永远空白。
// 必须在 initialize() 之前调用，返回 0 = 成功，非 0 = 失败（原因取 lastError()）。
export const setLogFile: (path: string) => number;

// 环境诊断（im_get_environment）。diagnostic 是 Core 里 ohos_probe::probe() 的原话，
// 它把"为什么看不到设备"分成了互斥的几种结论：
//   · "USB DDK 可用，可见 N 台 Apple 设备"
//   · "USB DDK 可用但看不到 Apple 设备：驱动配置信息里需要包含 VID 0x05AC"
//     ⇒ module.json5 的 extensionAbilities / metadata 没声明
//   · "OH_Usb_Init 返回 201" ⇒ 权限检查失败：ACCESS_DDK_USB 没进签名 profile 的 allowed-acls
//   · "OH_Usb_Init 返回 27400002" ⇒ 连不上 DDK 服务：多半是**调用方不在
//     DriverExtensionAbility 生命周期内**（USB DDK 只允许在驱动扩展里使用）。
//     这条要去查"驱动扩展有没有被拉起"，与权限无关，别再看 allowed-acls。
// status !== 0 时 diagnostic 为空串，此时应显示 lastError()，不要当成"没问题"。
export interface EnvironmentDiagnostics {
  status: number;
  diagnostic: string;
  appleDevices: number;
  serviceInstalled: number;
  serviceRunning: number;
  standardUsbmuxAvailable: number;
}

export const getEnvironment: () => EnvironmentDiagnostics;

// ── 画面调节 / 圆角 / 旋转（OhosPreviewRenderer 管线）─────────────────────────
// 三者都返回 Result 码（0 = Ok，负数见上方枚举）。参数已是归一化后的浮点，
// 调用方负责把 UI 的百分制 / 角度换算成 CoreApi.h 约定的区间
// （brightness∈[-1,1]、contrast/saturation∈[0,2]、gamma∈[0.5,2]）。
export const setImageAdjustments: (
  brightness: number,
  contrast: number,
  saturation: number,
  gamma: number
) => number;
export const setPreviewCornerProfile: (
  normalizedRadius: number,
  curveExponent: number
) => number;
export const setWindowRotation: (quarterTurns: number) => number;

// 只改本地渲染尺寸与帧率上限（CoreApi.cpp:1303）。与 startCaptureWithOptions 不同，
// 这条对**正在进行的会话立即生效**（会同时改会话的 target fps 与预览渲染器上限），
// 所以界面上「应用画面设置」用它；有线投屏协议 / 解码器 / 色彩只能靠下次开始采集。
export const setVideoPreferences: (
  maxWidth: number,
  maxHeight: number,
  maxFps: number
) => number;

// ── AirPlay 接收端 + mDNS 广播 ──────────────────────────────────────────────
// 无线链路不经过 Core（Core 目前对无线只返回 not_implemented），由 NAPI 直接
// 驱动 vendored 协议库。mDNS 走"取走 → 广播 → 回报"三步，是因为
// @ohos.net.mdns 的 addLocalService() 是异步 Promise，同步 NAPI 里没法 await。

// OH_VideoDecoder 解码链断点定位（OhosVideoDecoder.cpp::DecoderDiag）。
// 三种典型形态（16:57 截图命中第一种）：
//   pushed=0, callbacks=0                       → 没真正进解码器（配置错/首次 push 卡）
//   pushed>0, callbacks=0                       → 解码器在解码中或堵死（无输出回调）
//   pushed>0, callbacks>0, withPixels=0         → 解码器有输出但全空（buffer size / 宽高不对）
//   pushed>0, callbacks>0, withPixels>0         → 解码链 OK，画面问题在渲染
export interface DecoderDiag {
  pushedInputs: number;        // 已成功调用 OH_VideoDecoder_PushInputBuffer 的次数
  outputCallbacks: number;     // OnNewOutputBuffer 被调用次数
  outputWithPixels: number;    // 其中像素非空的次数（真正解出帧）
  outputNoPixels: number;      // 其中 pixels 为空的次数
  outputTooSmall: number;      // 空像素的子集：attr.size < checked_nv12_buffer_size(w,h)
  inputTooLarge: number;       // 输入缓冲容量不够而整帧丢弃的次数（>0 = I 帧比解码器输入缓冲大）
  spsParseFailures: number;    // SPS 解析失败次数（>0 = 用了回退提示值配置解码器）
  lastAttrSize: number;        // 最近一次 OnNewOutputBuffer 的 attr.size（字节）
  lastOutputWidth: number;     // 最近一次 OnNewOutputBuffer 用的 width
  lastOutputHeight: number;    // 最近一次 OnNewOutputBuffer 用的 height
  lastConfigWidth: number;     // 最近一次 Configure 的 width（SPS 真值或回退提示值）
  lastConfigHeight: number;    // 最近一次 Configure 的 height
  lastSpsEncWidth: number;     // SPS 解析：编码宽（crop 前，16 对齐）；0 = 从未解析成功
  lastSpsEncHeight: number;    // SPS 解析：编码高
  lastSpsDispWidth: number;    // SPS 解析：显示宽（crop 后，Configure 实际用的值）
  lastSpsDispHeight: number;   // SPS 解析：显示高
  lastStreamWidth: number;     // OnStreamChanged 上报 width（0 = 从未回调）
  lastStreamHeight: number;    // OnStreamChanged 上报 height（0 = 从未回调）
  firstInputB03: number;       // 首个推入帧前 4 字节（大端打包；hex 展开 = 00000001 67 即 SPS 开头）
  firstInputB47: number;       // 首个推入帧第 5-8 字节
  strategy: number;            // 当前解码策略档位 0..3：0=硬件+编码尺寸 1=硬件+显示尺寸 2=软件+编码尺寸 3=软件+显示尺寸
  strategySwitches: number;    // 自动切换次数（>0 = 前面档位推帧无输出已换）
  idrFrames: number;           // 输入里识别为 IDR（nal_type=5）的帧数（0 = 流里没扫到关键帧）
  syncFlagged: number;         // 真正标了 AVCODEC_BUFFER_FLAGS_SYNC_FRAME 的帧数
  inbandParamSets: number;     // 在帧前拼接 SPS/PPS 的次数（不依赖 CODEC_CONFIG 是否被采纳）
  pushFailures: number;        // PushInputBuffer 返回非 OK 的次数（>0 = 此前"已推 N 帧"是假成功）
  setattrFailures: number;     // SetBufferAttr 失败次数
  lastPushError: number;       // 最近一次 push 失败的 OH_AVErrCode
  lastInputSize: number;       // 最近一次真正交给解码器的字节数（含 in-band 参数集）
  inputCapacity: number;       // 解码器分配的输入缓冲容量（0 = 从未拿到过缓冲）
  configHeadB03: number;       // Configure 用的参数集前 4 字节（00000001 67 = SPS 开头；…28 = 只有 PPS）
  configHeadB47: number;       // 参数集第 5-8 字节
  configures: number;          // configure_annex_b 调用次数（>1 = 中途换过参数集并重建解码器）
  decoderName: string;         // 实际创建的解码器组件名（含 hw/sw 标记）
}

// 预览渲染链断点定位（OhosPreviewRenderer.cpp::PreviewRendererDiag）。
// 解码器已出帧却仍黑屏时，这里能区分「根本没挂上 surface」与「挂了但每帧被丢」。
export interface PreviewRendererDiag {
  attached: number;            // 1 = 渲染泵在跑（EGL 上下文有效）
  attachCalls: number;         // attach() 被调用次数（每次 XComponent surface 就绪）
  attachFailures: number;      // attach 失败次数（>0 = 没建起 EGL，lastError 会说明）
  presentCalls: number;        // AirPlay 直推路径调用 present() 的次数
  pumpFrames: number;          // 预览泵（USB 路径）实际绘制的帧数
  drawCalls: number;           // draw() 进入次数（两条路径合计）
  drawOk: number;              // **真正画完且 swap 成功**的次数（>0 仍黑 = EGL/GL 层问题）
  dropNoDisplay: number;       // 未挂载时被丢弃的帧数（黑屏第一嫌疑）
  dropNotNv12: number;         // pixelFormat 不是 NV12 的帧数
  dropEmpty: number;           // nv12 数据为空的帧数
  dropZeroDim: number;         // 宽或高为 0 的帧数
  dropTooSmall: number;        // nv12 字节数 < w*h*3/2 的帧数
  swapFailures: number;        // eglSwapBuffers 失败次数
  makeCurrentFailures: number; // eglMakeCurrent 失败次数（>0 = 上下文没落在渲染线程上）
  reattachAttempts: number;    // 未挂载时的自愈重挂次数（上限 12、间隔 ≥1 秒）
  lastGlError: number;         // 最近一次绘制后的 glGetError()（0 = 无错）
  lastEglError: number;        // 最近一次 swap 失败后的 eglGetError()（0 = 未失败过）
  surfaceWidth: number;        // eglQuerySurface 得到的 surface 宽（0 = 查询失败/已失效）
  surfaceHeight: number;       // 同上，高
  lastFrameWidth: number;      // 最近进入 draw 的帧宽
  lastFrameHeight: number;     // 最近进入 draw 的帧高
  lastFrameBytes: number;      // 该帧 nv12 字节数（应 = w*h*3/2）
  lastFrameFormat: number;     // 该帧 PixelFormat 数值（Nv12 = 0，P010 = 1）
  lastFrameStride: number;     // 该帧行距
  lastError: string;           // 最近一次 attach 失败的原因（空 = 从未失败）
}

export interface AirPlayStatus {
  running: number;            // 1 = 接收端已启动
  raopPort: number;           // RTSP 端口
  airplayPort: number;        // AirPlay HTTP 端口
  mdnsPending: number;        // 待广播的服务数
  mdnsRegistered: number;     // 已确认在网上广播的服务数
  mdnsFailed: number;         // 广播失败的服务数
  mdnsPendingRemoval: number; // 待注销的服务数
  mdnsActive: number;         // 1 = 原生 mDNS 响应器正在广播（取代 @ohos.net.mdns）
  mdnsAnswered: number;       // 已应答的 mDNS 查询数（>0 说明 iPhone 真来问过）
  mdnsLocalIp: string;        // 应答里 A 记录用的本机 IP（连接靠它，写死会"搜到连不上"）
  mdnsError: string;          // 原生响应器最近一次启动失败原因
  mdnsDroppedSelf: number;    // 被"来源为本机"闸门丢弃的包数（>0 说明本机探针的 0 应答是自家规则所致）
  mdnsAnnounceSent: number;   // 主动宣告 sendto 成功次数（一直为 0 = 从没宣告出去）
  mdnsAnnounceFailed: number; // 主动宣告 sendto 失败次数
  mdnsOutIface: string;       // IP_MULTICAST_IF 内核实际生效地址（不是 Wi-Fi 地址 = 宣告走错网卡）
  mdnsLastFrom: string;       // 最近被应答的查询来源 IP（是不是 iPhone，一眼可判）
  mdnsLastAnswerIp: string;   // 该次应答里 A 记录用的 IP
  // ── "问了什么 / 我们手里有什么"：专治"两个病症状一样" ──
  // iPhone 的「屏幕镜像」只认 _airplay._tcp 的 PTR，但它顺手也会问 _raop._tcp，
  // 两条我们都答得上，mdnsAnswered 照样涨。于是：
  //   mdnsQueryCounts 里 _airplay 为 0  → iPhone 从没问过 _airplay（宣告没出去）
  //   有 _airplay 但没有"答"           → 我们手里没有 _airplay 服务（注册掉了）
  //   mdnsServices 里缺 _airplay._tcp   → 同上
  mdnsLastQuery: string;      // 最近收到的一条查询：名字 类型 ← 来源（未应答会写明原因）
  mdnsQueryCounts: string;    // 分类计数：_airplay N(答 M) / _raop … / 服务枚举 … / 其他 …
  mdnsServices: string;       // 当前真正持有并已宣告的服务清单（空 = 一条都没注册上）
  audioPackets: number;       // 已收到的音频包数（raop 交给我们的次数）
  // ── 音频是否真出声（判据成对，缺一分不开"没数据"与"没出端点"）──
  //   audioPackets 涨 + audioFramesPlayed 不涨 → 数据进来了但没人取
  //   audioPackets 不涨                        → raop 那侧就没有音频数据
  audioFramesPlayed: number;  // 渲染器真正送给系统端点并播放的帧数
  audioBytesFed: number;      // 已喂进音频渲染器的 PCM 字节数
  audioUnderruns: number;     // 欠载次数（>0 = 供数跟不上，听感断续）
  audioDroppedFrames: number; // 因积压被丢弃的旧帧
  audioFlushes: number;       // iPhone 下发的 flush 次数（暂停/切歌/seek）
  audioOpenFailures: number;  // 建流失败次数（>0 时看 audioError）
  audioRendererActive: number; // 1 = 音频流已建立且处于播放态
  audioFormat: string;        // 当前音频格式，例 "44100Hz/2ch/16bit"
  audioError: string;         // 最近一次建流/播放失败原因（空 = 无错）
  videoFrames: number;        // 已收到的视频帧数（尚未解码）
  decodedFrames: number;      // 已真正解出并送到预览的帧数（≠ videoFrames：解码链是否通的判据）
  videoQueueDropped: number;  // 因解码跟不上收包被丢弃的旧视频包数（>0 = 会掉帧，但延迟不累积）
  videoConfigPackets: number; // 收到的 SPS/PPS 参数集包数（0 = 解码器从未被配置）
  // 参数集自愈账：SPS/PPS 不再只认配置包，凡是 NAL type 7/8 都收。
  videoParamFromConfig: number;  // 从配置包收到（或更新）参数集的次数
  videoParamFromFrames: number;  // 从数据帧里补到参数集的次数（>0 = 配置包不可信）
  videoParamReconfigures: number;// 因参数集变化重建解码器的次数
  videoWaitingParam: number;     // 因没凑齐 SPS+PPS 而没敢解码的数据帧数
  // NAL 账本：流本身是不是 H.264 / 有没有关键帧。
  videoNalSlice: number;         // 含 slice（type 1/5）的帧数
  videoNalIdr: number;           // 含 IDR（type 5）的帧数（0 = 等不到关键帧）
  videoNalSps: number;           // 含 SPS（type 7）的帧数
  videoNalPps: number;           // 含 PPS（type 8）的帧数
  videoNalNone: number;          // 一个 NAL 都扫不出来的帧数（>0 = 加密没解开/不是 H.264）
  videoDecodeErrors: number; // OH_VideoDecoder::OnError 累计次数
  videoDecoderLastError: string; // 最近一次 OnError 的错误码文本
  decoderDiag: DecoderDiag;      // 解码链断点定位（pushed/callbacks/size 等）
  previewDiag: PreviewRendererDiag; // 渲染链断点定位（attach/draw/丢帧原因等）
  clients: number;
  name: string;
  hwaddr: string;
  lastError: string;
  lastLog: string;
}

// txt 是已编码好的 DNS-SD TXT 记录：一串 [1 字节长度][key 或 key=value]。
export interface AirPlayService {
  id: number;
  name: string;
  type: string; // "_raop._tcp" 或 "_airplay._tcp"
  port: number;
  txt: Uint8Array;
}

// name 为空时用 "iPhoneMirror"；password 为空表示不设密码。
export const airplayStart: (name: string, password: string) => number;
export const airplayStop: () => void;
export const airplayGetStatus: () => AirPlayStatus;
// 队列空返回 null。
export const airplayTakeService: () => AirPlayService | null;
// 队列空返回 0。
export const airplayTakeRemoval: () => number;
// 广播完成后必须回报：ok=false 时 reason 会显示在 AirPlay 状态里。
export const airplayReportService: (
  id: number,
  ok: boolean,
  reason: string
) => number;
