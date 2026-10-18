# iPhoneMirror 鸿蒙 PC 版 v1.1.0 更新说明

> 本版本为 minor 升级（1.0.x → 1.1.0），核心是**沉浸光感视觉体系**与**系统托盘**的落地，并顺带统一了下拉菜单风格与设置持久化。

## ✨ 新增：沉浸光感（Immersive Glow）

- 全新辉光组件 `GlowLayer`（基于 Canvas 渲染），可为按钮、卡片、状态指示等元素叠加径向 / 边缘辉光。
- **三档强度**：弱 / 均衡 / 强，分别对应不同的辉光半径、透明度与模糊半径。
- **悬停反馈**：鼠标移入时辉光淡入、移出淡出（200ms 缓动过渡）。
- **状态动画**：采集状态用 `pulse`（连接中）/ `blink`（异常）等动画表达，辉光颜色随状态变化（警告黄 / 成功绿 / 错误红）。
- **性能自适应降级**：`GlowDegradationMonitor` 持续监控帧耗时，连续多帧超时（>33ms）自动关闭辉光动画，负载恢复后自动恢复，避免低端机掉帧。
- **系统级材质**：`module.json5` 启用 `ohos.arkui.UIMaterial.state=enable`，使 Select 下拉、Navigation 标题栏、Toast 等原生控件也带系统沉浸光感（强度由系统设置控制，App 仅负责开 / 关）。

## 🖥 新增：系统托盘（Tray）

- `StatusBarTray` + `TrayManager`，支持状态栏图标（深 / 浅色两套图标资源）。
- 关闭或最小化窗口后驻留后台，通过**常驻通知** + `EntryAbility.onPrepareToTerminate` 拦截整应用级退出，从 Dock / 通知栏一键唤回主窗口。
- 新增权限 `ohos.permission.PUBLISH_NOTIFICATION`、`ohos.permission.PREPARE_APP_TERMINATE`（均为 normal + system_grant，安装即授权，不弹框、不触发 ACL 使能）。

## 🧩 新增：统一光感下拉 `MaterialSelect`

- 封装官方 `Select`，统一光感风格的下拉按钮与下拉菜单，菜单项带辉光态；修复此前下拉"重启后为空、需先点选才显示"的问题。

## 💾 新增：设置持久化 `AppPreferences`

- 主题、语言、分辨率、帧率、解码偏好等设置落地 Preferences，重启后保留。

## 🔧 改进与底层

- 主界面接入光感开关与托盘；约 20 个子窗口统一光感 / 菜单风格与主题。
- 新增 `WindowVisibilityController`：窗口隐藏时暂停光感渲染，减少后台开销。
- `OhosVideoDecoder`：零像素帧针对性重试 + 策略链 / 参数集诊断。
- `OhosAirPlayReceiver`：接收侧若干修正。

## ⚠️ 已知范围

- 本版聚焦视觉与交互升级。上游完整能力（截图、全屏、MP4 录制、视频投屏、多设备）仍在对照补齐中。
- 沉浸光感强度（强 / 均衡 / 弱）由**系统设置**（设置 > 桌面和个性化 > 沉浸光感）控制，App 内仅提供开 / 关与档位读取。

## 📦 安装

需在 HarmonyOS PC / 2in1（API 26+）设备通过 DevEco 构建 HAP 安装；USB 采集需含 `ohos.permission.ACCESS_DDK_USB` 的调试签名 profile。
