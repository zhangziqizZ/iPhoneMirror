# 更新日志

> 鸿蒙移植版的变更说明。**每次改动都要**：① 递增 `AppScope/app.json5` 的
> `versionName`（以及 `versionCode`）；② 在本文件顶部加一节，写清新增功能或
> 修复的 bug；③ 同步更新 `entry/src/main/ets/pages/windows/AboutWindow.ets`
> 里的 `CHANGELOG_RELEASES` 常量（关于页「版本更新」区块按版本分组折叠读取它，
> 因为打包进 App 的资源无法随包读取本文件）。
>
> 版本号规则：`主.次.修订`（semver）。功能/修复 → 修订位 +1；较大功能 → 次位 +1。
> `versionCode` = 主*1000000 + 次*1000 + 修订。

## 1.0.43（2026-10-02）

### 优化：镜像画面延迟（队列深度 + 解码输出拷贝）

对照上游 Windows 版（`D3D11PreviewRenderer` / `MediaFoundationDecoder`）逐项核对后，
把加在「收包 → 上屏」这段路上的两笔固定开销去掉：

- **视频队列上界 12 → 3**（`OhosAirPlayReceiver.cpp`）。这是**端到端延迟的直接一项**：
  队列里躺着 N 个包，解码线程就比实时落后 N 帧（60fps 下 12 帧 = 200ms，30fps 下
  = 400ms）。而直播镜像里旧帧**没有任何价值** —— iPhone 那一秒的画面早就过去了，
  早播出来才有意义。当初定 12 是为「解码慢时别丢帧」，但那种情形下正确的做法恰恰
  是丢帧（保住实时性），不是排队（把延迟攒起来）。留 3 而不是 1，是给异步解码器
  一点余量，同时避免 Wi-Fi 抖动脉冲被当成积压直接丢掉。
- **丢帧时避开关键帧**（新增 `ContainsIdr()`）。原来无脑丢最旧的数据包，若队首正好
  是 IDR，丢它等于把后面引用它的一整段 P 帧全作废（画面花掉/停住好几秒，直到下一个
  IDR）。现在从最旧开始找第一个**非 IDR** 的帧丢；全队都是 IDR 时才退让丢队首。
- **解码输出拷贝整块化**（`OhosVideoDecoder.cpp`）。`stride == width` 时（多数硬件
  解码器的实际情形）Y/UV 各**一次** `memcpy` 就够；原写法无条件逐行拷贝，1080p
  每帧要做 1080 + 540 = 1620 次调用，60fps 下每秒近十万次函数调用，纯属加在这条
  路上的税。同时绕开了 `vector::resize()` 的零初始化（每帧白白多写一趟 3MB）。

### 优化：声音清晰度（回调粒度对齐包长 + 缓冲下调）

- **回调粒度对齐一包**（`OhosAudioRenderer.cpp`）：`OH_AudioStreamBuilder_SetFrameSizeInCallback`
  设为 480 帧。上游 `raop_buffer.c` 把 AAC-ELD 解码输出固定为 N_SAMPLE = 480 样本/帧
  （立体声 16bit = 1920 字节），所以一包永远是 480 帧。若不设，OHAudio 按自己的默认
  粒度开口（通常远大于一包），而我们每 ~11ms 才攒够 480 帧 ⇒ **每次回调都差一截、
  只能在尾部补静音**。那是有规律的可闻噪声（闷、断续、发虚），不是偶发欠载 —— 正是
  用户报的形态。让「取」和「喂」同拍，这类系统性缺口就没有了。
- **起播门限 / 高水位下调**：原来沿用 WASAPI 的绝对值（3072 / 5120 帧 ≈ 70ms / 116ms），
  现在按包算 —— 起播 4 包 ≈ 43ms、高水位 6 包 ≈ 65ms。够吸收 Wi-Fi 抖动，又不至于让
  声音明显落后于画面。
- **开流后回读真值并记日志**：实际拿到的采样率、回调帧数、`AUDIOSTREAM_LATENCY_TYPE_ALL`
  全链路延迟。请求的和 granted 的常常不是一回事（设备有最小粒度、采样率可能被端点改），
  不回读就只能靠猜。

### 变更：反控接管期间默认**不再**收起本地指针

用户明确要求「反控中鼠标不要消失」。上游 Windows 版与 macOS「iPhone 镜像」都会藏本地
光标，理由是屏幕上同时出现两个指针会让人不知道该看哪个 —— 但那两个实现里 iPhone 侧的
指针**一定能动**；鸿蒙这边的蓝牙 HID 反控仍是实验性的，一旦对端没配对上或指针不动，
藏掉本地光标就等于把用户唯一的位置反馈也拿走（鼠标凭空消失、连桌面都没法正常用）。

- 默认改为 **保持可见**；想要上游那种观感的人可在「设置」里**自己打开**
  「反控接管时收起指针」（新增一项，走 `AppPreferences` 落盘，跨启动保留）。
- 关掉的那一拍**立即恢复**指针，不等下一次 500ms 轮询自愈。
- 保留原有的「每轮重算 + 自愈」逻辑：任何漏掉的退出路径仍会在 500ms 内自动纠正，
  指针不会永久停在隐藏态。

## 1.0.42（2026-10-02）

### 新增：界面语言真正可切换（简体 / 繁中香港 / 英文）

> 此前「界面语言」下拉是**没有作用的选项**：选了只改下拉自己的选中态，界面文案恒为简体中文；
> 开发者工具里甚至直接回一句「当前不支持」。本版把它做成真的多语言。

- 新增运行时多语言层（`entry/src/main/ets/common/i18n.ets`）：以**简体原文为 key** 查表，
  `t()` 在 `build()` 期间读 AppStorage 的语言档位建立联动 ⇒ 切档时整树自动重渲染，
  无需逐个组件挂 `@StorageLink`（查不到译文时原样返回中文，不会白屏）。
- 主窗与开发者工具的下拉都接到 `set_language()`，切换后**立即生效**：左侧导航（投屏/投屏来源/
  设置/设备绑定器/输出/驱动/关于）、投屏按钮（开始投屏/停止投屏）、画面工具（调节画面/独立窗口/
  刷新画面/全屏预览/录制与推流）、设置项标签（应用模式/界面语言/应用主题）、页脚按钮
  （高级设置/关于/开发者工具）以及「敬请期待」浮层。
- 四个档位：**跟随系统 / 简体中文 / 繁體中文（香港）/ English**，「跟随系统」按系统语言判定；
  下拉的选项文案本身也随当前语言变化。
- 档位**跨启动保留**：`@ohos.data.preferences` 显式 `putSync` + `flushSync` 落盘（与半透明
  同一套机制），启动时在 UI 装载**之前**读回 AppStorage。
- 同时切换系统层偏好（`i18n.System.setAppPreferredLanguage`），让 resources 里的权限/能力说明
  也跟随；该接口失败不影响运行时翻译（界面仍显示所选语言）。

### 修复：切语言不刷新的两处根因

- 主窗左侧导航的文案此前写在**模块级常量数组**里（`NAV_MAIN`），只在模块加载时求值一次 ⇒
  即使加了翻译也永远不会刷新。改为每次渲染时构造（`nav_main()` / `nav_footer()`）。
- 开发者工具的语言下拉此前写的是一个只有它自己认识的键（`PARAM_KEY_LANGUAGE`），与主窗互不
  同步；现统一走全局语言档位键，并去掉「只有 zh-CN 一档可用」的占位文案。

## 1.0.41（2026-10-02）

### 修复：浅色模式下「设置中心」等次要按钮文字不可见

- `SecondaryButton` 的文字/底色此前用的是 DarkTheme 的**静态常量**（近白文字 + 白 8% 底），
  不随主题切换 ⇒ 浅色模式下画在浅色卡片上就是白字白底、整列隐形。改为 `@StorageLink`
  自取主题调色板（与宿主页面同一机制），主窗 + 12 个子窗口的所有次要按钮一次修复。

### 调整：关于页「版本更新」旧版本固定折叠

- 只有最新版本默认展开、可收起/再展开；旧版本只显示「版本号 + 日期」一行、**不可展开**
  （完整历史看仓库 `CHANGELOG.md` / GitHub Releases）。同时去掉 `aboutToAppear` 里读
  `@Prop` 再拷给 `@State` 的时序依赖 —— 真机上旧版本出现过展开态，本版从根上消除。

## 1.0.40（2026-10-02）

### 新增：半透明窗口（Acrylic）—— 对齐 Windows 11 深色观感

> 本节汇总 1.0.31–1.0.39：这些改动都属于**同一个功能**的迭代（含中间两次纠错与一次实机探测），
> 对外只算一个新版本，中间不再单列。

- 窗口底色半透明，UI 里本来就是 Fluent 半透明 token 的色板（如侧栏 `#C41F1F1F`）真正透到桌面。
  浓度可在「投屏设置 → 应用设置 → 半透明窗口」下选档：**78% / 60% / 50% / 40%**，默认 **60%**，
  点一下立即生效；开关一键回到原纯色背景。
- **开关与浓度档位跨启动保留**（`@ohos.data.preferences` 显式 `putSync` + `flushSync` 落盘）。
  此前用 `PersistentStorage.persistProp` 实测在用户直接关掉/杀进程时来不及落盘 ⇒ 选完重启又回
  默认值；改用 `dataPreferences` 每次改动即时写盘（详见 `entry/src/main/ets/common/AppPreferences.ets`）。
  开发者模式则**有意**保持非持久化（调试入口，每次启动都该是关闭态）。
- **真正入口是「窗口容器配色」，不是窗口背景色**：`setWindowContainerColor()` +
  `setWindowShadowEnabled()`（均 @since 20，SessionManager），配
  `ohos.permission.SET_WINDOW_TRANSPARENT`（normal + system_grant ⇒ 声明即授权、**不需 ACL**，
  自签 profile 同样有效）。`setWindowBackgroundColor()` 只是**窗口内**的兜底色，系统合成器
  不认它的 alpha ⇒ 单靠它做不出透视 —— 这正是最初"改了却根本没变化"的原因。
- **官方约束**：`setWindowContainerColor()` **不支持将非焦点态下的主窗口背景设为透明**
  ⇒ `inactiveColor` 必须是不透明色，否则返回 **401**（该码不在 `@throws` 列表内，是框架层参数
  校验直接拒的 ⇒ 别照着 `@throws` 列表排除可能性）。启动时做 4 组分级探测、逐组记录成功或
  失败码，**最后一次成功的组合生效**；账本与 `窗口透明=是/否` 等参数读数**仅在开发者模式下**
  显示在设置面板（正常使用者看到只会困惑）。
- 失焦时容器色取**主题实色**（深 `#FF1F1F1F` / 浅 `#FFF3F3F5`）而不是探测用的纯黑
  ⇒ 失焦窗口变实色、不发黑，与 Win11 一致。
- 实机已确认生效（读数：窗口透明=是、容器配色探测成功）⇒ **转为正式特性**，界面不再标
  「实验」；磨砂模糊能否采到桌面取决于系统合成器，最坏只是"半透明无磨砂"，不影响功能。
## 1.0.30（2026-10-01）

### 新增：关于页「版本更新」改为按版本分组折叠（参考微信更新日志）

- 最新一版默认展开，旧版本默认收起；点版本行即可展开/收起查看该版本的变更。
- 各条变更归入其所属版本，不再把所有版本的条目混在一个平铺列表里。

## 1.0.29（2026-10-01）

### 新增：开发者模式（调试入口，连点版本号 7 次开启）

「关于」页的版本号改为可点击：连点 7 次开启开发者模式，主界面空状态随即显示
有线链路诊断（原生 / 系统 USB / USB 权限 / 环境诊断 / 驱动绑定 / USB 驱动 / 窗口）；
再次点击版本号即关闭。`devMode` 经 `AppStorage`（`DEVELOPER_MODE_KEY`）由 `@StorageLink`
跨窗口（关于子窗 ↔ 主窗）联动，非持久化（仅内存，重启即失效），与上游「调试开关」语义一致。

### 修复：左侧面板收起后中间显示区不自拉伸

原版 `MainWindow.xaml.cs` 在 `showMirroring/showDevices` 都为 false 时会把
`LeftPanelHost` 整列宽度置 0 并 `Visibility.Collapsed`。鸿蒙版此前始终保留左侧列占位，
导致关闭「投屏 / 投屏来源」后中间画面区不拉伸（关闭右侧面板却能拉伸）。
现改为：左右两个面板都关闭时**整列连同间隔一并省略**，中间 `center_panel` 以
`layoutWeight(1)` 自然占满剩余宽度；与上游行为对齐。

### 调整：右侧「投屏设置」卡片顺序对齐原版

上游 `ControlTitle="投屏设置"` 的卡片顺序是：① 无线 AirPlay ② 有线投屏协议
③ 画面与声音 ④ 蓝牙反控鼠标设置 ⑤ 视频应用投屏 ⑥ 应用设置（**应用模式在该卡片内**，
不是独立卡片）⑦ 设置中心。此前鸿蒙版把「应用模式」单列成一张卡片、顺序也不对。
现已移除独立「应用模式」卡，将其折叠进「应用设置」卡内，并整体按原版重排为 7 张卡。

* 同步：`app.json5` → 1.0.29 / 1000029；本文件新增本节；`AboutWindow.ets` 的
  `CHANGELOG_ITEMS` 新增对应条目。

## 1.0.28（2026-10-01）

### 修复：安装失败 code 9568289（第二轮——真正的拦路石是 WRITE_IMAGEVIDEO）

第一次（1.0.27）移出 `ACCESS_DDK_USB` 后安装仍被拒，说明还有别的 `system_basic`
权限在拦。查证 SDK 的 `PermissionDefinitions.json`：真正的根因是
`ohos.permission.WRITE_IMAGEVIDEO`——它的 `availableLevel` 实为 **`system_basic`**
（1.0.25 一度误标成 `normal` 才把它写进 `requestPermissions`、还顺手申请了相册写入）。

* 把 `WRITE_IMAGEVIDEO` 从 `entry/src/main/module.json5` 的 `requestPermissions`
  **临时移出**（与 `ACCESS_DDK_USB` 一并），安装不再被权限授予关拦下。
* **截图改为存应用私有目录**：`capture_screenshot()` 不再经 `photoAccessHelper` 写系统相册，
  而是 `componentSnapshot` 截预览帧 → 编码 PNG → 写
  `filesDir/iPhoneMirror/Screenshots/YYYYMMDD_HHMMSS.png`。应用私有目录无需任何权限即可写，
  因此去掉 `WRITE_IMAGEVIDEO` 后截图照样能用。
* 代价：截图不再进系统相册，用户在「文件管理 / 关于页打开日志目录」同级的 `Screenshots`
  文件夹里取走；USB 有线采集仍暂不可用（需带该 ACL 的 profile）。
* 影响范围核对：`normal` 级权限（INTERNET / KEEP_BACKGROUND_RUNNING / ACCESS_BLUETOOTH /
  ACCESS_EXTENSIONAL_DEVICE_DRIVER）均不需 ACL，移出两条 `system_basic` 后安装通过。
* 恢复相册写入：拿到含 `WRITE_IMAGEVIDEO` ACL 的 profile 后，放回 `requestPermissions`
  声明并把 `capture_screenshot` 改回写相册即可（string.json 里 `imagevideo_perm_reason` 已留作 reason）。
* 同步：`app.json5` → 1.0.28 / 1000028；`module.json5`（移除声明）/ `Index.ets`（截图改存应用目录）已改。

## 1.0.27（2026-10-01）

### 修复：安装失败 code 9568289（签名 profile 缺 ACCESS_DDK_USB 的 ACL）

装包被拒：`9568289 = ERR_APPINSTALL_GRANT_REQUEST_PERMISSIONS_FAILED`。根因是
`ohos.permission.ACCESS_DDK_USB`（`system_basic` 级）必须进签名 profile 的
`acls.allowed-acls`，而本工程当前调试 profile（`.p7b`，AGC 签发、本地不可改）没有它。

* 把 `ACCESS_DDK_USB` 从 `entry/src/main/module.json5` 的 `requestPermissions`
  **临时移出**。其余 5 条权限均为 `normal` 级、不需 ACL，故移出后安装不再被拦。
* 影响：USB 有线采集暂时不可用（原生 `OH_Usb_*` 会回权限错，UI 显示「未发现设备」，
  且已修好的日志会如实记录）；**AirPlay 无线镜像 / 截图 / 全屏 / 日志 / 蓝牙反控**
  全部不受影响、可正常安装使用。
* 恢复 USB：在 AGC 把 `ohos.permission.ACCESS_DDK_USB` 加进受限权限(acl)、重新下载
  `.p7b` 替换后放回 `requestPermissions` 即可（详见 module.json5 注释）。

## 1.0.26（2026-10-01）

### 修复：关于页「实时日志」始终空白（原生日志路径错配）

根因：原生 `Core/src/Logging.cpp` 默认把诊断日志写到**系统 temp 目录**
（`iPhoneMirror-capture.log`），而关于页的读取器 `read_log_tail()` 只读应用沙箱
`filesDir/iPhoneMirror/Logs/`。鸿蒙应用沙箱读不到系统 temp，于是日志框永远空着、
「打开日志目录」也是空文件夹。

* **原生侧新增重定向出口**：`Logging.cpp` 增加内部 `g_path_override` 覆盖路径，
  `configured_path()` 优先用它；新增公开 `set_log_file_override()` → C ABI
  `im_set_log_file()` → NAPI `setLogFile()`（已同步 `types/libim_core/Index.d.ts`）。
  `set_log_file_override()` 会关闭当前已打开的日志文件，让下一次写入按新路径
  （应用沙箱）重新打开，因此即使在 `im_initialize()` 之后调用也有效。
* **ArkTS 侧**：`EntryAbility.onCreate` 在最早时机（早于任何原生写入）调用
  `setLogFile(filesDir + '/iPhoneMirror/Logs/startup.log')`，把原生日志落进沙箱。
  沙箱目录由原生 `create_directories` 自动创建。
* **读取器加固**：`read_log_tail()` 优先选 `startup.log`（原生固定文件名），避免日志轮转
  产生的 `startup.log.1` 被误读。
* 注意：日志内容在**首次原生写入**（开始投屏 / AirPlay / 任意原生诊断）之后才会出现，
  这是预期行为——没有会话就没有可记的日志。
* 同步：`app.json5` → 1.0.26 / 1000026；`module.json5` / `string.json` 无变化。

## 1.0.25（2026-09-30）

### 补齐原版两处功能：截图、全屏预览

对照原版（WPF + Linux 移植）的功能清单，把此前"恒灰 + 敬请期待"的两项接上真实实现：

* **截图**：预览快捷条与主投屏面板各有一颗「截图」按钮，点一下截下当前预览画面（预览
  XComponent，`id='preview'`），编码为 PNG 后写入系统相册。首次会弹「相册写入」授权框
  （`ohos.permission.WRITE_IMAGEVIDEO`，normal + user_grant，与蓝牙权限同纪律：声明不等于
  已授权，由 `ensure_media_permission()` 在点击时申请）。保存成功/失败都如实写进设置面板状态行，
  不假成功。（⚠️ 更正：1.0.28 起「写入系统相册」已改为存**应用私有目录**——详见 1.0.28；
  原因：`WRITE_IMAGEVIDEO` 实为 `system_basic` 权限、自签调试 profile 拿不到 ACL，已临时移出该声明，
  故截图不再进相册，改存 `filesDir/iPhoneMirror/Screenshots/`）
  * ★ 已知边界（已在按钮可用性 / 文案里标明，不骗人）：预览是 `XComponent(SURFACE)`，
    个别 API 版本 / 设备上 `componentSnapshot` 可能截不到 surface 内容（存下来是黑图）。
    若你实测是黑图，告诉我，我再加一条原生帧拷贝路径（`OhosPreviewRenderer` 留帧 + NAPI）。
  * 独立窗口开着时主窗口预览区是空的（渲染器已挪到独立窗口），此时主窗口截图无意义，
    按钮按此关掉可用性。
* **全屏预览**：预览快捷条与主投屏面板各有一颗「全屏预览」按钮，点一下把主窗口切到沉浸
  全屏（隐藏状态栏 / 导航栏），再点退出。用 `window.setWindowLayoutFullScreen` +
  `setWindowSystemBarEnable` 实现，不碰 free-window 模式，不会触发 relaunch。
* **可用性口径**：两项都从"恒灰"改为"有画面时可用"（复用 `can_use_visual_tools()`，并额外排除
  独立窗口开着的情况），与「独立窗口」「刷新画面」同一套状态驱动逻辑，不再用"未实现"假门槛。
* **未实现清单收窄**：`NOT_IMPLEMENTED_ACTIONS` 仅剩 `media`（录制与推流）—— 它要编码管线，
  本版仍未接。其余（image/refresh/bluetooth/window/screenshot/fullscreen）均已接真实实现。
* 同步：`app.json5` → 1.0.25 / 1000025；`module.json5` 新增 `WRITE_IMAGEVIDEO` 权限声明；
  `base/element/string.json` 新增 `imagevideo_perm_reason`。

## 1.0.24（2026-09-29）

### 反控改成「显式声明为实验性」——界面、文档、issue 模板同步

用户指出：这一版的反控其实还在实现阶段（iPhone 侧始终不出现指针），但界面上写的是
「蓝牙反向控制已广播」，看起来像**功能已经好了**。这正是"不许假成功"要拦的东西 ——
`isAdvertising()` 为真只说明 GATT 服务起来了，**不代表链路可用**。本版把成熟度声明
补到所有会被读到的地方（**未改协议层、未改任何 HID 行为**）：

* **预览快捷条那颗按钮**：文案由 `蓝牙反向控制已广播` 改为 `蓝牙反控（实验）已广播`
  （新增 `reverse_label()`，三个状态 `未启用 / 已广播 / 已连接` 一律带「（实验）」）
* **蓝牙反控鼠标设置卡片**：标题下方新增一行 `WARNING` 色 + 加粗的显眼声明 ——
  「实验性功能（开发中）：反向控制仍在实现阶段，本版本不保证可用……」
* **短摘要行**（`reverseShortDiag`）前缀加 `反控（实验·开发中） · `，避免把
  `订阅1` 读成"成了"
* **设置面板状态行**：`蓝牙反向控制已开启（实验·开发中，不保证可用）……`
* **`BluetoothHidPeripheral.statusText()`**：三态文案同步带「（实验）」
* **「等待连接 / 已连接」提示窗口**（`BluetoothControlNoticeWindow.ets`）：新增
  平台独有的成熟度声明行（上游没有这一条），显示在 5 步配对清单**之前**；
  `Connected` 态标题改为 `蓝牙反向控制已开启（实验）`；两态的写死窗口高度
  各 +50（`Waiting 520→570`、`Connected 280→330`），否则那两行会被裁掉
* **文档**：`README.md` 顶部加「⚠ 请先读：当前版本的功能成熟度」段、关键能力表该项
  改标 🧪（新增"实验性（开发中，不保证可用）"标记）；`SUPPORT.md` 新增 § 〇
  「实验性功能：反控仍在实现阶段」，并在 § 三 前加"先读 § 〇"提示；
  `docs/项目简介.md` 能力表加行、已知技术限制加条；两份 issue 模板同步措辞

## 1.0.23（2026-09-24）

### 蓝牙反控诊断「主机: 读N 写N 订阅S + 配对命中W」单独抽成显眼一行

1.0.22 修完后用户反馈「iPhone 始终没显示自己的鼠标指针」。1.0.22 的所有诊断字段
都接到了 UI 状态行，但用户根本没看到完整内容 —— 状态行用 `fontSize 9` + 单行
（`maxLines` 没设）显示一长串用 `·` 拼起来的读数，**单行被截断后用户只看到「蓝牙反控
已广播」一句话**，「复制诊断」按钮虽然在卡片里但因为视觉挤在一起也找不到。

**这一版只改可见性，没改协议层**：

* 新增 `@State reverseShortDiag`，由 `refresh_bluetooth_status()` 每轮重算，**只包含**
  `主机 读N 写N 订阅S + 应答失败N + 已配对X台(命中)` 这一段
* 在「蓝牙反控鼠标设置」卡片的「复制诊断」按钮**上方**独立显示一行：`fontSize 12`
  + `FontWeight.Medium`；订阅1 ⇒ 绿（链路通了），其它 ⇒ 橙（要点"与 iPhone 配对"，
  或要看下面那一长串）
* 状态行原 `Text(bluetoothStatus)` 加 `maxLines(10)`，**长串可换行**——以前单行截断
  后用户根本看不到完整字段
* 空态占位从「当前未开启蓝牙反向控制。」改成更明确的「当前未开启蓝牙反向控制（点上方
  按钮启用）」——少一个句号都能被当成"功能坏了"

`types 0 错 / alias 0 嫌`。根因（1.0.22 的 GATT 应答）等待 1.0.23 装机后用「复制
诊断」按钮的输出来定位 —— 三个现场读数足以区分「iPhone 端配置问题」与「投递问题」。

## 1.0.22（2026-09-24）

### 修「iPhone 上永远不出现系统指针」：GATT 服务端一直没履行**应答义务**

用户现象一句话：**独立窗口里本地指针被藏了（= 接管成立），但 iPhone 上从头到尾没有它
自己的鼠标指针**。这条现象把范围又推了一层 —— 手机不知道"自己有鼠标"，说明 iOS 连
HID 设备都没建起来，**根本还没走到上一轮猜的"报文投递到哪个特征"**。

#### 根因（官方文档明文规定，我们漏了）

* 华为《通用属性协议开发指导》原文：「**收到读取特征值请求时，需要调用 sendResponse
  进行回复对应特征值的数据内容**」。
* OpenHarmony 框架层文档同样写明：**Read request —— needRsp 恒 true ——
  Must call sendResponse()**，而且**描述符请求永远需要应答**。

而 1.0.21 的实现在 `register_and_advertise()` 里只注册了两个回调：

```
server.on('connectionStateChange', …);
server.on('characteristicWrite',   …);   // 且回调里也不应答
```

⇒ iOS 枚举 HID 设备时必然要做的这几步**全部无声超时**：
读 HID Information(`2A4A`)、读 **Report Map(`2A4B`)**（HID 描述符，最大的一份）、
读 Report Reference(`2908`)、写 CCCD(`2902`)**订阅**。
**Report Map 拿不到 ⇒ iOS 建不出 HID 设备 ⇒ 手机上永远不出现指针**，而且对端不会
给任何错误提示 —— 这正是"看着全对、就是不动"的另一种形态：**对端在等我们回话，
而我们连"听到了"都没记**。

#### 修法

1. 补齐四个应答处理器：`characteristicRead` / `descriptorRead` / `descriptorWrite`
   新增，`characteristicWrite` 在 `needRsp` 为真时也应答；应答统一带请求自带的
   `deviceId` / `transId` / `offset`（`ServerResponse{status:0}`）。
2. 值表按 UUID 查：`2A4A`→HID Information、`2A4B`→Report Map、`2A4E`→当前协议模式、
   `2A4C`→`[0x00]`、`2A4D`→**最近一次线格式**（`notify()` 里留存，SINGLE 已含 id 字节）；
   `2908`→`[reportId, 0x01]`（SINGLE 下 id=0）、`2902`→当前订阅值。
3. 协议模式/控制点属性放宽成 **写 + 免应答写都收**。HOGP 规定控制点是 Write Without
   Response，但主机实现不保证（上游对协议模式声明的是 Write）—— 只声明其一，另一种
   写法的 ATT 请求会被栈直接拒掉，而**我们这侧连回调都不会有**。
4. 去掉挂在 **Report Map 上的 Report Reference 描述符**（Report Reference 是 Report
   特征专属的；上游只给 Report 特征创建它），少一个多余差异。

#### 新增：主机侧交互账本（这一轮最重要的可诊断项）

| 读数 | 含义 |
|---|---|
| `主机 读0` | 主机连上了却**什么都没读** ⇒ 问题在配对/加密/广播内容，不在服务内容 |
| `主机 读N 订阅0` | 主机读到了 Report Map，却**不订阅** Report 特征 ⇒ 描述符/加密 |
| `主机 订阅1` | 真订阅了 ⇒ 之后才轮得到"报表投递落点"那一类问题 |
| `应答失败N` | >0 时"主机没来"这个结论**不可信**（我们可能收到了却没能回话） |
| `已配对N台(命中)` | iOS 对 HID 要求加密链路；鸿蒙没有 protection level 可设，绑定与否只能靠它观察 |

#### 新增 UI：**「复制诊断」按钮**（上一轮"没有读数反馈"的直接教训）

上一轮把六段账放在独立窗口条带上，结果用户一条读数都没回报 —— 让他在几个短句里找
数字不可靠。现在一次点击把**整段诊断**（输入侧 6 行 + HID 侧 12 行，全是真值、没有
"正常/异常"这类需要二次解释的词）写进剪贴板，直接粘贴即可。

顺带两项：
* 「**与 iPhone 配对**」按钮：鸿蒙 `GattProperties` **没有"要求加密"这一项**（离线 SDK
  原文只有 read/write/notify/indicate 等开关），无法像上游那样用
  `ReadProtectionLevel = EncryptionRequired` 逼 iOS 配对 ⇒ 只能靠"用户在手机上配对"
  或"我们从这侧 `connection.pairDevice()` 发起"。后者一次点击可验证。
* 设置面板的引导文案改成与上游用户手册一致的准确路径：
  **「设置 → 辅助功能 → 触控 → 辅助触控」开启，并在该页「设备 → 蓝牙设备」里配对**。
  （原写法「设置 → 辅助触控 → 指针设备」在 iOS 18+ 上路径不对：指针控制被移进了
  辅助触控，**不开辅助触控则 iPhone 根本不显示指针**，哪怕 HID 一切正常 —— 上游
  README 第 84 行与 USER_GUIDE 第 110/117 行都是这个前提。）

#### 本轮核对过、**确认无误**的项（别再重复怀疑）

* **Report Map 与上游逐字节相同**：脚本比对 `BluetoothHidMouseService.cs` 的 `ReportMap`
  与我们的 `HID_REPORT_MAP` ⇒ **189 字节，完全相同**。描述符内容不是问题。
* `HID_INFORMATION` 与上游同值 `[0x11,0x01,0x00,0x03]`（bcdHID=0x0111、国家码 0、
  Flags=0x03 RemoteWake+NormallyConnectable）。
* 广播已带 HID 服务 UUID `0x1812` 且 `connectable: true`。
* ⚠️ 鸿蒙 `AdvertiseData` **没有 `appearance` 字段**（离线 SDK 只有 serviceUuids /
  manufactureData / serviceData / includeDeviceName / includeTxPower / advertiseName）
  ⇒ 无法像常规 HID 外设那样声明"我是鼠标(0x03C2)"。仅此一条属于平台限制，先记下。

#### 若仍无指针，请按这个顺序看读数

1. `广0` → 通道没起来（权限/广播）。
2. `广1 连0` → iPhone 还没连上。
3. `广1连1 读0` → 主机连上了却什么都没读：**去 iPhone 上配对**（辅助触控 → 设备 →
   蓝牙设备），或点「与 iPhone 配对」。
4. `读N 订阅0` → 主机读到了却不订阅：把 `复制诊断` 的内容发来（要看 `描述符` 一栏是否
   含 `2902`）。
5. `订阅1` → 才轮到报文投递/协议那一层。

## 1.0.21（2026-09-22）

### 定位「独立窗口里指针藏了、却操控不了」的结构性成因

现象收窄成一句话：**接管是成立的**（本地指针按接管态被藏起来），但 iPhone 一动不动。

接管判据是 `指针在画面上 && isAdvertising() && isConnected()`（`ReverseControlInput`
的 `sync_takeover()`）—— 也就是说「指针被藏」这件事本身就证明了：**广播在开、iPhone
已经连上**。于是故障只可能在「报文发出去之后」这一段。

#### 根因：鸿蒙发通知只能按 UUID 定位特征，而 HOGP 的 Report 特征本就是 5 个同 UUID 实例

离线 SDK 的 `@ohos.bluetooth.ble.d.ts` 里，`NotifyCharacteristic` 只有
`serviceUuid` / `characteristicUuid` / `characteristicValue` / `confirm` 四个字段 ——
**没有描述符、没有特征句柄**；`notifyCharacteristicChanged` 也只有 callback / promise
两个重载，都不接受更多定位信息。

而 HOGP 的标准布局恰恰是：**每个 report id 一个 Report 特征、共用 UUID 0x2A4D**，靠
Report Reference 描述符（0x2908）区分 report id —— HID Service 规范 2.5.3.2 还明确
"同一 Report 类型存在多个实例时 Report ID 必须非零"。上游 Windows 版能工作，是因为
WinRT 的 `GattServiceProvider` 按**特征对象**投递，它没有这个缺口。

⇒ 5 个同 UUID 的特征摆在那里，通知落到哪一个**由协议栈决定**。落在 8 字节的键盘特征
（或只读的 feature 特征）上时，iOS 按那个特征的 report id 去解析 6 字节的鼠标位移，
只能整帧丢弃：**计数全在涨、手机一动不动**。

#### 改法：单 Report 特征 + 载荷首字节带 report id（默认）

`HID_LAYOUT_SINGLE`（默认）：只建**一个** Report 特征，Report Reference 的
Report ID = 0（规范只要求"有多个实例时非零"，只有一个实例时允许为 0），所有 report
共用它，**载荷首字节是 report id**：

```
鼠标 [0x02, buttons, x_lo, x_hi, y_lo, y_hi, wheel]   （7 字节）
键盘 [0x01, modifiers, reserved, usage×6]              （9 字节）
```

这正是 Android 手机当蓝牙键鼠外设时用的那套布局，iOS / Windows 都认；0x2A4D 只剩
一个实例 ⇒ 按 UUID 投递不再有歧义。

依据（三条，逐条记下来免得下次重查）：

1. **HID Service 规范 2.5.3.2 原文**："Report ID shall be nonzero in a Report Reference
   characteristic descriptor where there is **more than one instance** of the Report
   characteristic for any given Report Type." —— 约束的是**实例数**；本布局每个
   Report Type 只有一个实例 ⇒ 描述符里填 0 是规范明确允许的。
2. **USB HID 的父规则**：接口承载一个以上 Report ID 时，报告**必须**以 Report ID
   作为数据的首字节（BLE 那边之所以改用"一特征一 id"，正是因为 BLE 没有管道头）。
   我们的 Report Map 声明了 id 1–5 ⇒ 载荷带 id 是必须的，宿主读 Report Map 后
   自然按首字节分流。
3. **现成先例**：成熟的 Android BLE-HID 外设库（jp.kshoji.blehid）注册的就是
   **单个 Input Report 特征**、Report Reference 值 `{0, 1}`（Report ID 0 + Input）。
   与我们这套配置逐字段一致。

`HID_LAYOUT_MULTI`（对照）：原样保留上游的 5 特征布局（载荷不带 id）。设置面板的
「蓝牙反控鼠标设置」卡片里新增 **HID 布局** 一行（显示当前布局 + 「切换布局」按钮）——
切换会重建 GATT 服务（iPhone 要重连一次），但一次点击就能证伪"到底是不是布局问题"。

### 顺带修掉一条会让独立窗口从零重来的弯路

`open_standalone_window()` 原来照抄上游 `MainWindow.xaml.cs:5028-5029`，在开独立窗口前
**先关掉蓝牙反控**。上游要关，是因为它的反控输入由"当前持有画面的那个窗口"承接，换窗口
就得重建通道；鸿蒙这边两个窗口都常驻承接层 —— "谁在悬停"由 `setHoverSource('main'
/'standalone')` 按来源登记，"有没有画面"由 `setPictureAvailable` 单独报，通道本身不必动。

而关掉的代价很实在：要经历"停广播 → 关 GATT 服务 → 重新 `addService` → 重新广播 →
iPhone 重新连接"，**而独立窗口恰恰是用户要操控手机的那个窗口**。现在改成不关。

### 独立窗口条带上的读数改成「必定可见」

原先 `readoutText()` 在通道没起来时返回**空串**（理由写的是"条带是标题栏，不该常驻
一段与当前操作无关的说明"）—— 结果是：一旦没连上或没广播，**唯一的现场证据也不显示**。
"什么都没显示"和"通道没起来"在用户眼里完全一样（这正是上一轮"栏上什么都没有"的原因）。

现在改成：

- `未启用 <布局> 广0连0` / `待机 <布局> 广1连0` / `接管 移N 原N 送dx,dy 鼠N …`
- 只有「从来没接管过、也没在广播」时才返回空串（这时不占条带位置）
- 条带读数宽度 230 → 300（文案变长了）

其中 `广1连0`（广播着但 iPhone 没连上）是最容易被漏判的一格 —— 此时一切都是静默的。

### 验证方式（一次构建就能定性）

装好后把鼠标移到画面上，看独立窗口条带（或主窗口设置面板的状态行）：

| 读数 | 含义 |
|---|---|
| `未启用 … 广0` | 通道没起来 → 回设置里点「开启蓝牙反向控制」 |
| `待机 … 广1连0` | 广播着但 iPhone 没连上 → 去 iPhone「设置 → 辅助功能 → 触控 → 辅助触控 → 设备」配对 |
| `待机 … 广1连1` | 连上了，但指针不在这块画面（或这个窗口没有可操控的画面） |
| `接管 移0 无事件` | 事件没递到承接层 |
| `接管 … 送dx,dy` 在变、`鼠N` 在涨、手机仍不动 | 我们这侧全正常 → 点一次「切换布局」做对照 |

本轮**零 C++ 改动**：DevEco rebuild + 重装 HAP 即可，不需要 clean rebuild。

## 1.0.20（2026-09-22）

### 修「构建失败」：ArkTS 不做「布尔别名收窄」

真机构建（DevEco）在 1.0.19 上报：

```
10605999 ArkTS Compiler Error
Argument of type 'number | undefined' is not assignable to parameter of type 'number'.
At File: .../entry/src/main/ets/common/ReverseControlInput.ets:710:23
```

原因是 1.0.19 里为了让探针与派发共用一次判空，写了

```ts
const rawPresent: boolean = rawDx !== undefined && rawDy !== undefined;
if (rawPresent && this.rawUsable) { this.onRawDelta(rawDx, rawDy); }   // ← 这里报错
```

**tsc 会把 `rawPresent` 记成"保留的条件"，随后自动收窄 `rawDx/rawDy`；ArkTS 编译器不会**，
它只看每个变量自己的声明类型 ⇒ `rawDx` 仍是 `number | undefined`。

修法：把两个 `!== undefined` **直接写进那个 `if` 条件里**（一次判空一次用，不再借用别名）。
本工程的类型自检脚本走 tsc，**会放过**这种写法 —— 所以"自检 0 错误"不等于"能编过"。

### 新增 `tools/check_alias_narrowing.py`（补上这个盲区）

专门扫"靠布尔别名收窄"的写法：找到 `const 名 = <含 `!== undefined`>` 后，再看它的每个
`if (名 …)` 分支里有没有把这些操作数**当值用**（传参 / 赋值 / 参与算术），命中就报出
`文件:行` 与改法。在 1.0.19 的代码上跑，它精确命中 `ReverseControlInput.ets:710`
（与编译器报的位置一致）；修完再跑为 0 处。

```bash
python3 tools/check_alias_narrowing.py .   # 0 处嫌疑 = 通过
```

**规矩**：判空条件不要存进布尔变量再复用；`!== undefined` 写到哪就在哪判。

### 顺手修掉「键盘焦点」这条静默链路（鼠标能动、敲键盘没反应）

同一轮排查里发现取键盘焦点这条路也是"看起来正常、实际哑掉"的类型：

- **定位标识用错了属性**：`focusControl.requestFocus(value)` 的 `value` 是组件的
  **可寻址标识**，对应组件上的 `.id()`；而承接层一直写的是 `.key('…')` —— 新版 SDK 里
  `.key()` 已不再承担这个作用（真构建正是那条警告 "`key` can only be used for testing
  directories"）。⇒ 两处承接层改成 `.id()`（`preview_input` / `standalone_input`）。
- **没有成功/失败可读**：`UIContext.getFocusController().requestFocus(key)` 返回
  **`void`**（不是 boolean）。所以焦点的真值改由承接层自己的 `onFocus` / `onBlur`
  回报，并记进账本：接管中若没拿到焦点，独立窗口栏上会显示 **`无焦点`** ——
  否则"键盘哑掉"与"通道没通"在现象上完全一样，只能靠猜。
- **自愈**：两个窗口的 500ms 轮询里，只要"还在接管却没焦点"就再要一次
  （与藏指针同一套纪律：只在进入时做一次，漏一条路径就永久失效）。

## 1.0.19（2026-09-22）

### 修「独立窗口里指针藏了、却操控不了」

用户反馈：鼠标放到独立窗口的画面上，本地指针**确实隐藏**（说明悬停接管判据通过了），
但 iPhone 毫无反应。指针能藏 ⇒ 通道就绪、iPhone 已连上、hover 事件也到了，所以问题
只在「事件从承接层到发出去」这一段。按三条各自独立的静默失败路径修：

- **原始位移可能"字段存在但恒为 0"**：`MouseEvent.rawDeltaX/Y` 是可选的，但"可选"
  只说明它可能缺席，不保证"不支持时一定缺席"（触控板/转接鼠标可能填 0）。旧代码
  把"字段在不在"当成"能不能用"，于是永远走原始位移分支、永远发不出位移，而计数还在
  涨 —— 属于"看着在工作"的那种坏。现在加**可用性探针**：连续 6 次原始计数为 0、
  同时刻绝对坐标明明在动 ⇒ 判定本机拿不到原始位移，自动改走绝对坐标差分，
  结论与依据进状态行。
- **事件未必递到那层透明承接层**：在画面区**容器**上再挂一份接口做兜底（容器与承接层
  几何完全重合 ⇒ 局部坐标一致，语义相同；而它是"有子节点的容器"，是命中测试里最不会
  漏的一类）。同一事件被两处各收一次时按**事件指纹**去重（指纹只取与节点无关的
  `timestamp/action/button/windowX/windowY/rawDelta` —— 用 `x/y` 会对不上，因为它们是
  "相对当前组件"的坐标），去重次数进诊断，所以兜底路径有没有被用到是看得见的。
- **换算基准可能因解析失败而恒为 0**：`Area.width/height` 是 `Length`，允许
  `"402.00vp"` 这种字符串，`Number()` 会给 NaN 并被守卫挡掉 ⇒ 画面区尺寸永远是 0
  ⇒ 差分路径一步都算不出来。改走统一的 `length_to_vp()`（两个窗口共用）。
- **缺尺寸与落在黑边分开记账**：前者是"我们的基准没就绪"（可修），后者是"指针确实在
  画面外"（正常）。混成一个计数会把前者的故障看成后者的正常。
- **接管成立就把键盘焦点要过来**：键盘事件只发给有焦点的节点，原先靠"点一下画面"拿
  焦点；一旦点击落不到承接层，键盘就全哑。

### 独立窗口的「就地读数」（本轮最关键的可见性）

独立窗口是用户实际在用的窗口，却没有主窗口那条状态行。现在栏上有一行反控读数，
四段账互相独立，缺哪段就指向哪段的问题：

| 读数 | 含义 |
|---|---|
| `反控 待机` | 悬停没换成接管（没画面 / iPhone 没连上） |
| `接管 移0 无事件` | 接管判据过了，但一个移动事件都没递到承接层 |
| `接管 移N 原0 改差分` | 事件到了，原始位移不可用，已自动改走差分 |
| `接管 移N 送X,Y`（在变） | **我们这侧一切正常**，问题在手机/协议一侧 |
| `鼠N` 不涨 | notify 没成功；在涨而手机不动 ⇒ 手机侧不理这份报表 |

独立窗口另外补了一个 500ms 的状态轮询（原先只有主窗口在报「此刻有没有画面」，
主窗口不在前台时这边的接管态会停在过期值上；顺带刷新读数）。

状态行另外新增 `协议N`（iOS 写下的协议模式，1 = Report Protocol）：它是"iOS 认下这台
设备是 HID"的握手证据，恒为 0 就说明 iOS 根本没走 HID 握手。

> 一轮排查记录：曾怀疑"报文少了 report id 首字节"。核对**上游 Windows 实现**
> （`BluetoothHidMouseService.cs:752-830`，`payload = report`）后确认**不带 id 字节是对的**
> —— iOS/BlueZ 是从 Report Reference 描述符（0x2908）取 report id 的。所以本轮**没有**
> 改 HID 布局。但发现一个真实差异需要实机判定：上游按**特征对象**投递
> （`_mouseReport`），而鸿蒙的 `notifyCharacteristicChanged` 只能给
> `serviceUuid + characteristicUuid`，而 5 个 Report 特征**共用 0x2A4D** ——
> 到底通知到哪一个由栈决定。

### 怎么验证（一步定性）

装好后把鼠标放到画面上，**先在 PC 键盘上随便敲几个字**：

- **键盘能输入、鼠标不动** ⇒ 通知落到了第一个 Report 特征（键盘那个），鼠标报表走错了
  特征 —— 那是布局问题，下一版改（单一 Report 特征 + id 首字节，或把鼠标特征排到最前）。
- **键盘也不动、读数里 `送X,Y` 在变** ⇒ 我们这侧全正常，问题在手机：确认 iPhone 的
  「设置 → 辅助功能 → 触控 → 辅助触控」已开启（iOS 靠它提供鼠标指针，不开则外接鼠标的
  报告不会被处理），并确认蓝牙里这台电脑显示"已连接"。
- **读数显示 `移0 无事件`** ⇒ 事件层没通，把这一行发我。

## 1.0.18（2026-09-22）

- **修复「按钮不能实时刷新」**：投屏面板的「独立窗口」「刷新画面」、工具条的「独立窗口」，
  以及工具条上的蓝牙文案，此前**永远停在打开界面那一刻的状态** —— 投屏都开始了它们还是
  灰的，蓝牙都连上了还写着「蓝牙反向控制未启用」。
  根因不是状态没更新（`poll_status` 每 500ms 都在更新），而是**渲染通道选错了**：
  ArkUI 规定「@Builder 传入的参数是两个或两个以上、且未使用按回调传递时**不会触发动态
  渲染**」，「按值传递时状态变量的改变**不会**引起 @Builder 函数内的刷新」（只有
  「仅一个参数 + 直接传对象字面量」才走按引用传递、才会刷新）。原来的 `tool_button` /
  `quick_button` 各有 5 个参数、全是按值传递 ⇒ 这些节点只在首帧创建一次，之后永不更新。
  截图里唯一亮着的「调节画面」恰好是把可用性写死 `true` 的那个，正对上这条判据。
  修法：这几处改为 `@Component` + `@Prop` 下发状态（父组件给新值 ⇒ 子组件必定重建，
  本工程已有 `RefreshIconButton` / `SettingsToggle` 两处先例），主题由子组件自己
  `@StorageLink` 订阅。
- **同一族一起修掉**（都是「把会变的值当参数传进 @Builder」）：
  · **四格统计**（分辨率/帧率/延迟/音频）3 个参数 ⇒ 此前永远显示首帧的「—」，
    看起来像"统计功能坏了"；现改为 `StatCell` 组件。
  · **画面调节窗口的四个数值**（亮度/对比度/饱和度/伽马）此前拖动滑杆数字不动，
    改为内联 `Text`（与工程里既有的两处同类修法一致）。
  · **设置面板里蓝牙状态行**同理改为内联。
- **设备列表的选中高亮改为确定性行为**：`device_row` 是单参数 @Builder、参数本身不变，
  会变的是渲染时读的 `selectedUdid` —— 这类官方文档没有明说，工程里也拿不到反例，
  所以**不宣称它此前是坏的**。但它与上面几处一样不可依赖，故改为 `DeviceRow` 组件经
  `@Prop` 下发选中态，并在 `ForEach` 的 key 里带上选中与连接状态（ArkUI 的 `ForEach`
  只按 key 决定复用与否，key 不变就不重跑该项的更新）。至此「选中态 / 可用性 / 动态
  文案」一律不走 @Builder 参数，这条规矩比个案结论可靠。

## 1.0.17（2026-09-22）

- **鼠标放到画面上就能操控（无感接管）**：此前必须先到设置面板点「开启蓝牙反向
  控制」，且输入承接层是随开关动态挂载的 —— 于是 `onHover` 永远等不到第一次悬停
  （鼠标移上来时那层还不存在），只能靠先点一下把它创建出来。现在承接层**常驻**，
  进入画面即接管、移开即释放；通道也改成**惰性启动**（第一次把鼠标放到画面上时
  才申请蓝牙权限、开广播），避免一开应用就弹权限框。
- **接管期间隐藏本地系统指针**：否则屏幕上两个指针各走各的，用户不知道该看哪个。
  藏指针是全局状态，所以做成**每轮重算 + 自愈**（而不是"进入时藏、离开时显"）——
  漏掉任何一条退出路径都会让指针永久消失，那比功能不可用严重得多。
- **指针移动改用 `rawDeltaX` / `rawDeltaY`**（@since 15）：这两个字段是鼠标硬件的
  原始相对位移，不经过屏幕坐标。老做法是拿本地绝对坐标做差分，而 iOS 的蓝牙鼠标
  只吃相对量、它那侧光标是自己累加出来的 —— 本地光标一旦被窗口边缘挡住（差分变 0）
  或跑出窗口（事件断流），iPhone 光标就跟着卡住，跨一次窗口位置就再也对不上。
  字段取不到时自动退回老路，**降级次数**显示在状态行（可判断这台设备支不支持）。
- **独立预览窗口接入反向控制**：此前该窗口完全没有输入承接层 —— 而它才是日常真正
  在用的那个（主窗口让位显示占位）。现在两个窗口共用同一套事件翻译，悬停按**来源**
  分别登记（两个窗口交替发 hover 时到达顺序不定，单一布尔量会被过期的"离开"覆盖）。
- **画面区尺寸按来源记账**：它是灵敏度换算的基准（gain = 源逻辑宽 / 画面区宽），
  两个窗口大小通常不同，共用一个字段会出现"在独立窗口里划得正常、回主窗口就偏了"。
- **「有没有画面」与「指针在不在上面」分成两个量、每轮重算**：三种场合不许接管
  （还没有画面 / 画面已挪到独立窗口只剩占位图 / 独立窗口画面尚未挂载）—— 接管了却
  什么都操控不了，用户看到的现象是"鼠标突然失灵"。分开记的额外好处：鼠标先停在画面
  上、画面随后才出现（刚点开始投屏、独立窗口画面刚挂好）也能**自动接管**，不需要用户
  把鼠标移开再移回来才生效。
- **「停止蓝牙反向控制」不再被自动启动立刻推翻**：新增跨窗口的显式停用标志，
  自动启动前先问过它；另给外设 `start()` 加了**并发守卫**（两颗窗口同时惰性启动时
  会双双穿过 `started` 判断，各注册一遍 GATT 服务，现象是"广播着但永远连不上"）。
- **接管态与原始计数进诊断**：状态行会显示「★操控中」「接管 N 次」「rawΔ x,y」
  「降级(无rawΔ)N 次」—— 前者是"到底生效没有"的凭据，后两者是校准灵敏度滑杆的依据。

## 1.0.16（2026-09-21）

- **镜像卡顿（打开视频软件尤其明显）**：`raop` 的 RTP 收包回调里**同步**做 H.264
  解码，而单帧解码最多要等 50ms 才拿到输出 —— 网络收包被解码速率按住，高码率
  画面一上来就积压。现在收包线程只做「拷贝 + 入队」立刻返回，解码与上屏交给一条
  专属线程消费；队列上限 12 个包，满了丢**最旧**的非参数集包（保延迟不累积），
  丢了多少条数直接显示在状态行（「解码滞后丢弃 N 包」）。
- **投屏声音「很怪」（断续、发闷）**：音频写回调用错了门限 —— 原实现把「起播门限」
  当成**每次**回调的欠载判据，只要队列不足 3072 帧（约 70ms）就把整块输出成静音，
  等于「放一块、静音一块」，静音占掉约一半时间。现在门限只在**首次起播**拦一次，
  此后「有多少放多少、尾部补零」，欠载次数单独计数（可判断有无复发）。
- **蓝牙反控「特征数为 0」仍有误判**：注册后回读只走 `getService()` 一条路，且拿到
  2901008（not found）就直接下结论 —— 而 `addService()` 是跨进程调用，返回时机不
  等于「服务已可查询」，另外栈对 UUID 的规范化也会造成假阴性。现在两条路交叉印证
  （`getService` + `getServices` 全量比对，忽略大小写）并带**沉降重试**（最多 5 次 ×
  120ms，读到即返回），失败文案里带上证据（重试次数 / SDK 等级 / 探针原话）。
- 状态行现在会显示回读试了几次（`(沉降N次)`）与回读不可用的确切原因。

## 1.0.15（2026-09-21）

- **独立窗口不再有两套标题栏/三键**：上一版屏幕上同时出现系统标题栏
  （「iPhoneMirror 独立预览」+ 右上角两键）和自绘栏。原因是 `setWindowDecorVisible(false)`
  **调得太早**（在 `loadContent` 之前），实测不生效 —— 现在放到内容加载成功之后调，
  和 EntryAbility 里一直生效的写法对齐。
- **系统三键区也一并关掉**：官方在 2in1 上的语义是「隐藏标题栏后三键区会下沉到内容区
  保留」，所以只调 `setWindowDecorVisible` 还会有一套系统三键浮在画面右上角。
  补上 `setWindowTitleButtonVisible(false, false, false)` 把三键区整个关掉，
  屏幕上就只剩自绘的那一条栏。装饰隐藏结果会回读校验，失败原因显示在主窗口占位区。
- **自绘栏去掉「放大」键**：只保留 关闭 / 最小化（顺序仍按 macOS 左上角三键）。
- **自绘栏不再压住手机画面**：改成**预留条带**（条带在画面之外，永远占位，只有按钮
  淡入淡出）。★ 关键点：条带高度取**窗口宽度的固定比例**（8%），这样「窗口比例锁成
  常数」与「画面比例不被破坏」才能同时成立 —— 推导见 `WindowServices` 里的注释；
  写死 40vp 的话画面比例会随窗口尺寸偏到 2%。实测偏差 ≤0.06%（仅为整数取整）。
- **栏上不再放长文案**：短徽标（4~6 字）留在栏上，完整原因（圆角/比例锁/系统栏失败）
  移到主窗口「已在独立窗口打开」占位区显示，两边都不丢信息。

## 1.0.14（2026-09-21）

- **修复构建失败（hvigor 00303038 Configuration Error）**：`module.json5` 里
  新注册的 `StandalonePreviewAbility` 写了 `"windowSize": { minWidth, minHeight }`，
  而 **`windowSize` 只在 `module` 层有，`abilities` 的 schema 里没有这个字段**
  （报的是 `propertyNames: windowSize` / "must be equal to one of the allowed
  values"）。改成 abilities 层允许的 `minWindowWidth` / `minWindowHeight`
  （单位 vp），窗口下限语义不变。
  ★ 记法：`abilities` 里的窗口尺寸一律用 `min/maxWindowWidth|Height`、`min/maxWindowRatio`
  这一族平铺字段，不要嵌套成对象。

## 1.0.13（2026-09-21）

- **独立窗口升级为独立 UIAbility**：主窗口最小化后它照样显示。此前它是
  `mainWindow.createSubWindowWithOptions()` 建的**子窗口**，生命周期挂在主窗口上 ——
  主窗口一转入后台/最小化，它就跟着不显示了。官方的「独立子窗」
  （`SubWindowOptions.zLevelAboveParentLoosened`，不跟随主窗前后台切换）是
  **API 26** 的能力，本工程 `compileSdkVersion` 是 6.1.0(23)，没有这个字段；
  所以改成新增一个 `StandalonePreviewAbility`（刻意不声明 `process`，与
  EntryAbility 同进程 —— 否则 `libim_core.so` 的渲染器就是另一份，画面过不来）。
- **独立窗口新增可隐藏的三键浮层栏**（对齐 macOS「iPhone 镜像」）：
  最小化 / 放大·还原 / 关闭（macOS 黄/绿/红的顺序），外加「常驻」与
  「圆角/直角」两个开关。
  **鼠标移到窗口顶部热区（64vp）时浮出，移开 1.2s 后淡出隐藏**；鼠标停在栏上
  不会隐藏；点「常驻」可钉住不再自动隐藏（要拖动窗口时很实用）。
  窗口本身仍关着系统装饰（`setWindowDecorVisible(false)`），所以画面照样铺满整窗。
- **独立窗口只能等比例放大缩小**：用 `setContentAspectRatio()` 锁内容区宽高比
  （宽高比取源帧，未知时回退 201/437）。
  ★ 这个 API **只认主窗口、且只在自由悬浮窗（FLOATING）下生效** —— 这正是独立
  窗口必须从子窗升级为主窗的第二个理由。Ability 的 `supportWindowMode` 因此
  只给 `["floating"]`。锁比例失败时原因会显示在栏上。
- 联动改造：独立窗口的"还在不在"改由它自己维护的 AppStorage 标志判定（原来用
  `window.findWindow`，对独立 Ability 的窗口不适用）；主窗口请求关闭改走
  AppStorage；关窗后的「画面接回主窗口」收尾逻辑留在主窗口自己的轮询里执行，
  不再跨 Ability 回调主窗口的闭包。

## 1.0.12（2026-09-21）

- **修复「投屏没有声音」**：AirPlay 的音频此前**只计数、根本没接到播放器**——
  `RaopAudioProcess` 里只有 `g_audio_packets++`（源码注释也写着"等 Task 27 接入"）。
  现按 raop 回调给的 PCM（`pcm_data_struct`：`sample_rate/channels/bits_per_sample` +
  交错 PCM16）构造 ASBD，交给早就写好的 `OhosAudioRenderer`（OHAudio，与上游
  WASAPI/PipeWire 后端共用同一份 `PcmBufferPolicy` 队列策略）播放；并接上
  `audio_set_volume`（iPhone 音量）与 `audio_flush` 计数。
  几个必须处理的细节：静音填充包不填格式字段 ⇒ 记住上一份有效格式；采样率/声道变化
  时重建音频流；建流失败只记一次账，不按包刷异常。
- **音频诊断接到界面（判据成对，缺一分不开"没数据"和"没出端点"）**：新增
  `audioFramesPlayed/audioBytesFed/audioUnderruns/audioDroppedFrames/audioFlushes/
  audioOpenFailures/audioRendererActive/audioFormat/audioError`。状态行现在会直说
  「音频播放中 44100Hz/2ch/16bit（已播 N 帧）」，或指出「已收 N 包但 0 帧播放
  （渲染链未取到数据）」/「音频未收到数据」/「音频未出声：&lt;原因&gt;」。
- **修复「蓝牙控制无法启动：HID 服务注册后特征数为 0」的误判**：这条结论其实
  **站不住脚**。回读用的 `GattServer.getService()`/`getServices()` 是 **@since 22**
  的新接口，在低版本设备上调用会抛异常，而旧实现把这个异常 catch 成"0 个特征"，
  还被调用方的文案覆盖了真实原因 —— 等于**用一个坏掉的探针否掉了整个功能**。
  现在：只有 `2901008`（Gatt service is not found）才算有效证据；其他异常一律记为
  "回读不可用"，功能照常启动并给出隐患提示；`getService` 拿不到时用 `getServices()`
  按 UUID **忽略大小写**再找一遍（栈可能把 UUID 规范化成小写）。
- 蓝牙状态行同步区分「特征 N/9」与「特征未知(回读不可用)」，隐患常挂在状态里；
  新增 `readbackAvailable/readbackError/readbackServiceUuid/readbackCharUuids/
  apiVersion/lastWarning` 诊断字段（`apiVersion` = `deviceInfo.sdkApiVersion`，
  用于解释"为什么回读不可用"）。

## 1.0.11（2026-09-20）

- **新增「按真实 iPhone/iPad 外形适配」**（README 头号卖点）：按 Apple ProductType
  识别 iPhone X / 刘海屏 / mini / 标准 / Max / Dynamic Island，以及 iPad Pro / Air /
  mini / 全面屏基础款，为每台设备匹配各自的屏幕圆角与曲线；Home 键机型与旧款 iPad
  保持直角；未知新设备按画面比例保守回退（判定区间 0.38~0.56 视为手机、0.64~0.80
  视为 iPad，中间留缝不裁）。整表移植自上游 `DeviceCornerProfileResolver.cs`，
  **逐条对过答案**（`tools/check_corner_profile.js`，77 项全通过）。
- 独立预览窗口新增「圆角」开关：拖动、等比缩放之后轮廓仍按机型贴合
  （`onAreaChange` 重算，对应上游 WM_SIZE）。关闭即把归一化半径传 0 ——
  与上游 `_cornersEnabled ? _cornerRadius : 0` 同一语义。**入口与原版不同**：
  上游在右键菜单里，本工程此前没有引入过 `bindContextMenu`，故放在顶部细条上。
- 关窗时把渲染器圆角复位、并把画面接回主窗口；被系统直接销毁时也会兜底复位。
- 渲染侧**未改一行 C++**：`im_set_preview_corner_profile` 的超椭圆裁剪
  （`OhosPreviewRenderer` 片元着色器）与 napi 导出 `setPreviewCornerProfile` 早已就绪，
  本次只是补上"谁来算这两个数"。

## 1.0.10（2026-09-20）

- **修复蓝牙反向控制报「201 Permission denied」**：`ohos.permission.ACCESS_BLUETOOTH` 的
  `grantMode` 是 **user_grant**（module.json5 里只看到了 `availableLevel: normal`，就误判成
  "声明即授权"）。声明只是给申请资格，**必须运行时申请**，否则 `GattServer.addService()`
  直接回 201。现在 `BluetoothHidPeripheral.start(ctx)` 会先弹系统授权框，并在被拒时给出
  「去哪儿开权限」的具体指引；新增权限诊断账本（`permGranted/permRequestCount/permDeniedCount`）。
- **修复「独立窗口」按钮恒灰、点了只回一句"该操作需先开始投屏"**：可用性判据此前写成了
  `is_streaming()`（只认 USB 采集状态机的 state==4），比上游窄了两圈。上游是
  `CanUseVisualPreviewTools = (HasCaptureSession || IsMediaCasting) && ...`，
  且 **AirPlay 镜像根本不经过 CaptureState** —— iPhone 正在无线镜像时按钮仍是灰的。
  现在改为「有采集会话 **或** 正在经 AirPlay 出画面」。
- **修复 AirPlay 模式下独立窗口打不开**：开窗守卫此前要求 `has_device()`（USB 选中设备），
  而无线镜像时没有 USB 设备。现在按上游统一设备模型的语义，退回用 AirPlay 客户端名
  （`AirPlayStatus.name`），两者都没有才拒绝。
- **修复关闭独立窗口后主窗口预览回不来（会一片黑）**：渲染器只有**一个** EGLSurface，
  独立窗口开着时它挂的是独立窗口的 surface，而主窗口记的 `attachedSurfaceId` 仍是旧值 ⇒
  重挂逻辑判定"已经挂着了"直接返回。现在关窗时先清账再无条件重挂（对齐上游
  `QueueMainPreviewHostSync` 的无条件语义）。
- `BluetoothHidPeripheral.start()` 改为 `start(ctx): Promise<boolean>`；两个调用点
  （主窗口反控开关、设备绑定器的蓝牙配网）同步改为异步链，回调全部包 try/catch。

## 1.0.9（2026-09-20）

- **新增「独立预览窗口」**（原版 `NativePreviewWindow`）：点工具条上的「独立窗口」，
  预览画面会移到一个独立窗口里显示，主窗口原位出现一个圆形的「已在独立窗口打开」提示
  （84×84 圆形 + `WindowNew20` 34 号图标 + 21 号 SemiBold 文案，逐项对照
  `MainWindow.xaml:1471-1495` 的 `IndependentPreviewSurface`）。
  默认 720×900、最小 320×240、可按内容宽高比自由缩放，首次打开取工作区 **82%**
  （原版 `AspectRatioWindowController`，无源尺寸时回退 201:437）——全部按原版常量。
  **不需要改一行 C++**：渲染器本来就只有一个 EGLSurface，独立窗口做的是把同一个
  surface **重挂**到新窗口的 XComponent（`OhosPreviewRenderer.cpp:575-589` 每收到一个
  surface 请求就 `destroy_gl()` → `create_gl(newId)`），主窗口的 XComponent 因此
  在独立窗口存活期间保持「未挂载」，关窗后自动重挂回来。
- **新增「蓝牙反向控制」（BLE HID 反控）**：把 iPhone 当指针设备，用鼠标/滚轮直接操作
  手机。实现是一条真的 BLE HID 外设链路 —— `ble.createGattServer()` 注册 HID 服务
  （Report Map / Input Report / Protocol Mode 等特征）+ `ble.startAdvertising()`
  带上 HID 服务 UUID，供 iPhone 在「设置 → 蓝牙」里搜索并配对
  （`ets/common/BluetoothHidPeripheral.ets`）。**这是此前被误标为"鸿蒙做不到"的功能**：
  鸿蒙**有** GATT Server 与外设角色，代码里已经跑通；只有当设备/系统不具备 BLE 外设
  角色时才会失败，此时把 `801 Capability not supported` 原样报出来，不再含糊成"启动失败"。
- **反控输入采集与坐标换算**（`ets/common/ReverseControlInput.ets`）：采集预览区里的
  鼠标移动/按键/滚轮，按**渲染器实测的帧尺寸**（不是界面上写的分辨率）换算到手机坐标，
  再做边缘黑边剔除后组 HID Report 发出。
- **接线反控 UI**：设置面板的蓝牙反控开关改成真开关（开 = 真广播 + 真启用输入路由，
  关 = 停广播 + 停路由），状态行显示实时数据（GATT 特征数 / 各类 Report 计数 /
  连接与断开次数 / 未连接丢弃数 / 发送失败与超时数 / 最近一次发送错误）。
- **修复一批"鸿蒙做不到"的过时文案**（实为已实现）：`BluetoothConnectionWindow` 的
  「等待 HID 连接」引导、`BluetoothClientBindingWindow` 的平台替换说明、
  `DeviceBindingWindow` 的蓝牙卡说明，以及 `MEMORY.md` 里的对应结论，原先都写着
  「鸿蒙不支持 BLE 外设模式（无 GATT Server、不能 BLE 广播）」——那是错的。
- **设备绑定器的蓝牙连接改为真实现**（原版 `ConnectBluetoothClick`）：
  临时开一次 BLE HID 配网广播 → 打开「等待 Bluetooth HID 连接」窗口等 iPhone 配对 →
  选中客户端后保存绑定 → 无论成败都收掉这次广播。逐行对照
  `DeviceBindingWindow.xaml.cs:140-176`，其中 `configurationOnly: true` 的语义
  （**只广播、不接管输入**）也照做。蓝牙状态行不再恒为「已绑定 · 已断开」，
  它现在读的是真实 GATT 连接。
- **改造「等待 Bluetooth HID 连接」与「蓝牙客户端绑定」两个窗口的假数据**：
  等待窗口新增 500ms 实时状态（广播中 / 已配对数 / 未广播时给出该做什么），
  绑定窗口的「下一步」改为真枚举当前 GATT 客户端，刷新按钮给出真实数量，
  只有在真没有客户端时才退回首屏演示数据**并在界面上标注是演示数据**。
- **修掉主窗口蓝牙开关的状态漂移**：外设是单例，设备绑定器的配网流程会启停它，
  而主窗口此前只在"自己点过按钮"时改 `bluetoothOn`，会出现「按钮写着正在运行、
  实际什么都没广播」。现在每轮轮询都从外设真实状态回读，并在被别处停掉时同步关闭
  输入路由。

## 1.0.8（2026-09-20）

- **修复「只能在 DevEco Studio 里打开，桌面点图标直接跳到应用详情页」**：
  根因是 `entry/src/main/module.json5` 的 `EntryAbility` **完全没有 `skills` 声明**。
  DevEco 的 Run 走 `aa start -a EntryAbility -b <bundleName>` —— 直接点名 ability，
  不经过启动器；而桌面/应用中心点图标时，启动器是拿 bundleName **按 skills 里的
  entities + actions 反查**首页入口的，查不到就只能把你带到设置的应用详情页。
  现在补上标准入口声明：
  `entities: ["entity.system.home"]` + `actions: ["ohos.want.action.home"]`
  （两个字符串分别取 SDK `WantConstant.ENTITY_HOME` / `ACTION_HOME` 的值，
  `@ohos.ability.wantConstant.d.ts` 第 274 / 44 行）。
- 这一项**只影响安装包的启动入口声明**，与 AirPlay / USB 业务代码无关；
  但属于打包内容，必须重新构建并重装 HAP 才生效。

## 1.0.7（2026-09-20）

- **修复 AirPlay 投屏「已解码 163 帧、画面却全黑」的真正根因：跨线程使用 EGL 上下文**。
  上一版加的渲染链诊断把病根亮了出来 —— `present 163 / draw 163 / swap 失败 163`，
  而 `attach 1 / 败 0`（说明 EGL 建得成功）。EGL 上下文是**按线程 current** 的：
  `attach()` 由 ArkTS 的 onLoad 经 NAPI 调进来（跑在 JS 线程上）建上下文并
  `eglMakeCurrent`，而 `draw()` 跑在 AirPlay 的 RTP 线程上（USB 路径则是预览泵线程），
  于是 draw 里那句 `eglMakeCurrent` 必然失败 —— 而它的返回值被丢掉了。没有 current
  上下文时：① 所有 `gl*` 调用静默退化成空操作，`glGetError()` 恒返回 0；
  ② `eglSwapBuffers` 每帧返回 `EGL_FALSE`。症状就是"解码正常、报告画了 163 帧、
  画面全黑、一处报错都没有"。现在渲染器持有**一个专属渲染线程**，建 EGL / 绘制 /
  销毁 EGL 全在它上面执行，其它线程（JS 线程、RTP 线程、NAPI 调用）只投递请求、
  不碰 GL；顺带把 `present()` 从 RTP 热路径上的同步 GPU 提交摘了下来。
- **修掉渲染侧的假成功**：`draw_ok` 此前在 `eglSwapBuffers` 失败时照样 +1，
  状态行"成 163"其实一帧都没上屏。现在只有 swap 真成功才算画成。
- **渲染诊断补两个判据**：`上下文未就绪N`（`eglMakeCurrent` 失败次数，跨线程用 EGL 的
  指纹）与 `swap失败N(egl0x…)`（`eglGetError()` 错误码）；`glGetError` 也改为在 swap
  **之前**读取（原先在之后读，读到的是下一帧的现场，永远是 0）。
- **修掉「刷新画面」的假成功**：此前它无论渲染器死活都只写一句"预览渲染器已刷新"，
  从未调用 ABI。现在真的调用 `im_force_preview_refresh()`（新增 NAPI 导出
  `forcePreviewRefresh`），把真实结果回报给状态行 —— 未挂载 surface 时会如实说
  "刷新预览失败：尚未挂载预览 surface"。
- 修正 `Index.d.ts` 里 `lastFrameFormat` 的注释：`PixelFormat::Nv12 = 0`（原文写"应为 2"）。

## 1.0.6（2026-09-20）

- **未实现功能统一灰化 + 「敬请期待」提示**：此前未实现的按钮有两种糟糕表现 ——
  灰态按钮在 `onClick` 里被 `if (enabled)` 静默吞掉（点了完全没反应），部分按钮则
  只在设置面板里写一行没人看得见的字。现在：① 未实现的工具（蓝牙反控 / 录制与推流 /
  独立预览窗口 / 截图 / 全屏预览）**恒为灰态**，不再用"投屏中才可用"的假门槛让它们
  看起来像能用；② 点击时在窗口底部弹一条「敬请期待」浮层（2.2 秒自动消失），同时把
  确切成因写进设置面板状态行；③ 「蓝牙反控鼠标设置」「视频应用投屏」两张未实现卡片
  整体压暗，视觉上先于文字说明。
- **修正两处过时文案（实为已实现功能）**：工具条的「调节画面」与画面设置卡片里的
  「更多设置」此前点了只提示"待接入 GLES 色彩矩阵"——色彩矩阵（亮度/对比度/
  饱和度/伽马四路 uniform）与画面调节子窗口其实早已就绪。现在点击**真的打开**
  画面调节窗口，并**传入当前生效值**（否则窗口滑杆与画面实际状态对不上，
  一按"应用"画面就跳变）。
- **修复预览 surface 重建后不再重挂**：XComponent 的 surface 会被系统销毁重建
  （窗口最大化/还原、DPI 变化等），此时 onLoad 会带着**新的** surfaceId 再触发，
  而旧代码用 `surfaceAttached` 布尔直接短路，导致新 surface 永远没被挂载、渲染器
  仍握着一个已失效的 EGLSurface —— 症状正是「解码一直出帧、画面全黑、零报错」。
  改为比对 surfaceId，换了 surface 就重挂。
- **新增渲染链诊断**：`present → draw` 这条路上失败原本全是静默的（draw 有五条裸
  `return false`，`present` 在未 attach 时干脆什么都不做），黑屏时无从判断卡在哪环。
  现在逐分支计数（未挂载 / 非 NV12 / 空数据 / 零尺寸 / 字节不足 / swap 失败 / GL 错误）
  并记录最近一帧与 surface 尺寸，显示在「解码器状态」行上。

## 1.0.5（2026-09-19）

- **修复 AirPlay 投屏黑屏（已连接但画面全黑）**：诊断行显示四档解码策略
  （硬件/软件 × 编码/显示尺寸）全部推帧成功却零输出回调，说明根因不在"配置宽高
  口径"而在四档共用的**喂帧方式**。三处修复：
  ① 输入帧从不标关键帧 —— 现在用 NAL 扫描识别 IDR（nal_type=5）并标
  `AVCODEC_BUFFER_FLAGS_SYNC_FRAME`，解码器不必再等一个"同步帧"信号；
  ② 参数集只走 `OH_MD_KEY_CODEC_CONFIG`，各实现采纳口径不一 —— 现在额外把
  SPS/PPS 以 Annex-B 形式**前置拼接**到本解码器实例的首帧与每个 IDR 之前（裸流
  通用做法）；
  ③ `PushInputBuffer` 返回值此前被 `(void)` 丢弃后仍无条件累加"已推帧数"，
  push 失败也显示为成功 —— 现在只有真正成功才计数，失败次数与错误码进诊断。
- 诊断行新增喂帧量化字段：`真推N(IDR/标记/参数集)`、`推送失败N(err)`、
  `属性失败N`、`末帧NB/容量NB`，下次任何异常都能一眼定位。
- 同时修两处隐患：`SetBufferAttr` 失败时把空缓冲归还（否则输入队列卡死且无痕迹）；
  解码器重建/Flush 时清空输入缓冲与"本实例已推帧数"。
- **主窗口加最小尺寸 1280×700**（原版 `MainWindow.xaml` 的 `MinWidth`/`MinHeight`，
  DIP 折算为 px 后生效）：避免用户把窗口拖得过小，导致左侧图标条 + 预览区 +
  右侧控制面板三栏互相挤扁、控件重叠变形。
- **关于窗口导航栏对齐原版**：原版是 `SubWindowTabControl` + `SubWindowTabItem`
  的胶囊式导航栏（深色圆角容器 + 1px 边框 + 内边距 2，三段等宽，选中项
  `SelectionBrush` 圆角高亮、文字转强调色、字重恒为 SemiBold），移植版此前用
  ArkUI `Tabs` 的系统默认 bar，观感不一致 —— 现已按原版结构自绘并补上悬停态。

## 1.0.4（2026-09-19）

- 新增左侧导航项的名称气泡（原版 `ui:NavigationViewItem.ToolTip` 的复刻）：
  鼠标悬停约 1 秒后在该项右侧弹出名称说明气泡，移开即消失；相邻项之间
  100ms 内移动则立即弹出（对齐 WPF `ToolTipService` 的 InitialShowDelay/
  BetweenShowDelay 默认值）。气泡样式取自 WPF-UI 4.3.0 `DefaultToolTipStyle`：
  #2C2C2C 底 / 1px 边框 / 圆角 4 / 内边距 12 / 字号 12 / 行高 16 / 最大宽 260。
- `common/Theme.ets` 增加 `TOOLTIP_BACKGROUND` / `TOOLTIP_BORDER` /
  `TOOLTIP_FOREGROUND` 三个色键（深/浅两套，值取自 WPF-UI 4.3.0 库主题）。

## 1.0.3（2026-09-19）

- 复刻 Windows 版三横线按钮的按压反馈：按下时图标横向压缩到 0.66、松开弹回
  （各 80ms，出处 WPF-UI BasePaneButtonStyle 的 IconScaleTransform）。
- 展开动画时长修正为 160ms（实测 WPF-UI PaneStates Storyboard，原先凭印象写成 250ms）。

## 1.0.2（2026-09-19）

- 左侧导航栏展开/收起加平滑动画：点击三横按钮时 pane 宽度 48↔208 做约 250ms
  过渡（复刻原版 Fluent NavigationView 内建动效）。

## 1.0.1（2026-09-19）

- 修复 AirPlay 无线接收端 iPhone 搜不到设备的根因：mDNS TXT 记录长度字节多算 1
  导致 iPhone 全链解析错位；`model` 改为 `AppleTV2,1` 走 AirPlay1 协议栈。
- 修复 H.264 SPS 解析不剥 emulation prevention（`00 00 03`）字节、不解析
  frame_cropping，导致硬件解码器 Configure 宽高与码流不符、静默丢帧（黑屏）。
- 新增解码器策略自动切换链：硬件/软件 × 编码尺寸/显示尺寸四档自动轮试。
- 过滤 rtp/时间线程每包 DEBUG 日志，避免顶掉「原生」诊断行里的有效信息。

## 1.0.0

- 鸿蒙移植首版：USB 有线捕获 + AirPlay 无线接收、预览渲染、音频开关音量、
  亮度对比度饱和度伽马调节、圆角旋转、13/20 个子窗口。
