# iPhoneMirror · 鸿蒙 PC 版

**在鸿蒙电脑上投屏 iPhone。**

iPhoneMirror 鸿蒙版是上游 [iPhoneMirror](https://github.com/RayrenSX/iPhoneMirror)
（Windows 版）的鸿蒙 PC（HarmonyOS 2in1）移植：把上游的协议栈与采集状态机整棵搬过来，
只补一层鸿蒙平台实现（USB DDK / AVCodec / OHAudio / EGL / 自研 mDNS）。

USB 有线采集与 AirPlay 无线接收同在一套界面里，低延迟、不经过任何云端中转。

> 状态标记：✅ 已实现可用 · 🚧 已实现但开发中或待真机复验 · 🧪 实验性（**开发中，不保证可用**）· ⛔ 尚未实现

详细功能与代码结构见 [`docs/项目简介.md`](docs/项目简介.md) 与
[`docs/移植说明.md`](docs/移植说明.md)。

## ⚠ 请先读：当前版本的功能成熟度

本版本请把 **「USB 有线投屏 / AirPlay 无线接收 / 预览渲染 / 音频」当作主要功能**。

**蓝牙反向控制（鼠标放到投屏画面上操控 iPhone）仍在实现阶段，不保证可用。**
目前的表现可能是：iPhone 的蓝牙列表里能看到本机、也能配对成功，但 **iPhone 上
始终不出现鼠标指针**。这是**已知情况**，不是你的操作错了，也不是配置问题。

这条功能的问题是**欢迎反馈**的（我们需要现场数据才能往下推进），但请不要把它
当成"本版本应该能用"的功能 —— 它没有可用性承诺。提 issue 前请先读
[SUPPORT.md](SUPPORT.md) 开头那段，并按 § 二 的步骤 A 附上「复制诊断」的输出。

## 关键能力

- ✅ USB 有线投屏（iPhone/iPad，Lightning 与 USB-C）
- ✅ AirPlay 无线接收（局域网内 iPhone 屏幕镜像）
- ✅ D3D11/EGL 预览渲染、多设备并存
- 🧪 蓝牙反控鼠标（鼠标放到投屏画面上即可操控 iPhone）—— **开发者预览，仍在实现阶段，不保证可用**。iOS 18+ 用户另须开「辅助触控」+ 在系统蓝牙设置里配对，详见 [SUPPORT.md](SUPPORT.md)
- ⛔ 有线反控（上游靠外部 Python 桥走 usbmux + DDI；本工程不包含）

## 平台要求

- 鸿蒙 PC（HarmonyOS NEXT，2in1）
- iPhone/iPad：iOS 13.4+（iOS 18+ 反控需开「辅助触控」）
- 鸿蒙系统蓝牙权限（应用首次启用反控时会弹窗申请）

## 给用户的支持

- **遇到问题请先看** [**SUPPORT.md**](SUPPORT.md) — 含"必读的三步"（iOS 端配置 / 取诊断按钮 / 提交 issue 时必须贴的信息）
- **想知道哪些功能还没做** — 同上文件"已知不实现"一节

## 给开发者的参与方式

- **想贡献代码请看** [**CONTRIBUTING.md**](CONTRIBUTING.md) — 含构建步骤、两条自检脚本、提 PR 前的硬规则
- **了解工程整体策略** — [`docs/移植说明.md`](docs/移植说明.md)（面向维护者）

## 安全与社区

- [**SECURITY.md**](SECURITY.md) — 含 UDID / 配对记录 / USB 抓包的报告**请私密**，不要公开提 issue
- [**CODE_OF_CONDUCT.md**](CODE_OF_CONDUCT.md) — 社区行为准则（Contributor Covenant）

## 反馈

提 issue 请走本仓库的 [Issue 页面](../../issues)。
请按模板（bug 报告 / 功能请求）填好后提交；SUPPORT.md 里列了"必填信息清单"。

## 版本

完整变更日志见 [**CHANGELOG.md**](CHANGELOG.md)。

## 许可

本项目以 **GPL-3.0-only** 发布（上游同许可）。第三方组件各自保留其原始许可，
详见 [`LICENSE`](LICENSE) 与 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 免责声明

本项目**非 Apple 官方软件**，与 Apple Inc. 无任何关联。AirPlay 与 QuickTime
屏幕采集属于 Apple 的私有协议；本项目仅作自有设备调试用途。

---

_本项目是上游 iPhoneMirror 的衍生作品，遵循 GPL-3.0 section 5(a) 显著标注_
_modification notice：原项目见 <https://github.com/RayrenSX/iPhoneMirror>。_