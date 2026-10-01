# CONTRIBUTING.md · 开发者向

> 提 PR 之前请通读一遍。它会帮你：
> ① 知道**这个项目哪些规则是硬性的**（不要浪费一次 PR 的 review 时间）；
> ② 知道**怎么本地构建 + 跑自检**（很多问题本地就能复现并修）；
> ③ 知道**写 commit message / PR description 的格式**（自动化 changelog 的依据）。

---

## 一、核心纪律（**硬性**）

下面三条是**不可商量**的，对它们的破坏会让 PR 直接被 close。

### 1.1 上游文件零改动

本项目的 `cpp/Core/`、`cpp/types/libim_core/`、`entry/src/main/cpp/third_party/`
是**逐字节从上游搬过来的**。**对它们的任何"行为变更"都不允许**。

> **对上游既有文件只允许做接口抽取，不允许夹带行为变更；平台相关一律新增文件。**

允许的改动：
- 修复上游就有的 bug（要先在上游提 issue + PR，待合入后同步）
- 编译器版本差异导致的 ifdef（用 `#ifdef OHOS` 或类似宏，且**仅**在文件头）

不允许的：
- 在上游函数里塞 print
- 在上游类里加方法
- 把上游 `if (x) { ... }` 改成 `if (!x) { ... }`
- 重命名上游变量/函数

**怎么判定我是不是在改上游？** 看 `docs/移植说明.md` § 三 / § 四
（上游文件清单 + 平台层清单）。如果你动的是**不在平台层清单里的文件**，
要么改的是上游（不允许），要么你搞错了文件归属。

### 1.2 每次改代码**必做**清单

下面四件事**任何一件**漏了，PR 都会被退回来重做：

1. `AppScope/app.json5` 递增 `versionName` 与 `versionCode`（`versionCode` = 主*1000000 + 次*1000 + 修订）
2. `CHANGELOG.md` 顶部加一节
3. `entry/src/main/ets/pages/windows/AboutWindow.ets` 的 `CHANGELOG_RELEASES` 常量同步（按版本分组，最新一版默认展开）
4. 本地跑通两条自检（见 § 三）

### 1.3 禁止假成功

只在真成功路径自增计数（连接数、报表数、配对命中数等）。
"看起来对的兜底"是排错最大的敌人 — 一个 `else { count++; }` 就能让用户报错时拿到假的"通了"。

---

## 二、本地构建

### 2.1 环境

- DevEco Studio（任一能编 OpenHarmony 应用的版本）
- 鸿蒙 PC 真机（沙箱里编 HAP 不行 — 见下）
- Git（不要在 DevEco 自带终端里跑）

### 2.2 命令

```bash
# 1. 自检（不依赖真机，沙箱里就能跑）
python3 tools/check_arkts_types.py .      # 类型 0 错 3 警告（napi 28014）即可
python3 tools/check_alias_narrowing.py .  # 0 处嫌疑

# 2. C/C++ 翻译单元编译试跑
bash tools/try_compile.sh cpp/ohos/OhosAirPlayReceiver.cpp   # IM_LINK=1
bash tools/try_compile.sh cpp/ohos/OhosAirPlayReceiver.cpp   # IM_AIRPLAY=1

# 3. 构建 + 装 HAP（**必须在 DevEco 做**，本机无 JDK）
#    File → Sync and Refresh Project
#    Build → Build Hap(s) / APP(s) → Build HAP(s)
#    运行 / 调试 → 选择真机（USB 调试开启）
```

**沙箱里跑不了** HAP 构建（无 JDK）。DevEco 同步时若报"与已安装版本不兼容"，那是
compileSdkVersion 与本机 SDK 不匹配；按错误码 2902054 = "广播数据超长" 这类
**错误码自带含义**——别只看 message，要看 code。

---

## 三、自检脚本（**必跑**）

### 3.1 `tools/check_arkts_types.py`

```bash
python3 tools/check_arkts_types.py .
```

检查项：
- typescript@4.9.5（SDK 自带 ets-loader 补丁）扫所有 ets 文件
- **0 错误 / 3 警告 = napi 28014** 是预期通过的信号（这三警告就是 napi 库的提示性日志）

### 3.2 `tools/check_alias_narrowing.py`

```bash
python3 tools/check_alias_narrowing.py .
```

扫 `const alias = x !== undefined; if (alias) use(x);` 这种**靠布尔别名收窄**的写法。
ArkTS 编译器**不会**做这类收窄，tsc 能过但 ArkTS 真构建会报 **10605999**。

详见 [`docs/移植说明.md`](docs/移植说明.md) § 七「自检脚本」。

---

## 四、代码风格

### 4.1 ArkTS

- 严格模式 — 不允许 `any` / `unknown`，对象字面量必须已声明 class/interface
- `@Prop` 保留名（`enabled`/`background`/`borderColor` 等）→ 用 `usable`/`selected` 等业务语义名
- 自定义 getter 在新版 SDK 上被静默剥离 → 用方法
- `@Builder` 按值传递**不参与动态刷新** → 状态驱动的文案/数值/可用性走内联 `@Component`+`@Prop`
- 共享单例（BLE 外设/渲染器/采集会话）被多窗口启停时，"在不在运行"必须**回读真值**——别用本地缓存
- 生命周期/定时器回调里抛的异常没人接管 → **整个应用会被结束**，`.then/.catch` 包 try

### 4.2 C/C++

- 文件头统一以 `// ─── 路径/职责 ───` 起头，给一段该文件**做了什么**的注释
- 平台层 (`cpp/ohos/`) 用 `OHOS_LOG_*` / `printf` / `OHOS_DEBUG_LOG_*`，不要用上游的 `spdlog`（已确认上游用的是 `WIN32_LOG`）
- NAPI 导出走 `napi_bridge.cpp` 的 desc 表；**同步**补 `cpp/types/libim_core/Index.d.ts`
- 同 namespace 同签名非 inline 函数要先全局搜，**避免 ODR 冲突**

### 4.3 注释

- 写注释的"**为什么**"而不是"**做了什么**" — 代码本身在讲"做了什么"
- 涉及到内存所有权 / 生命周期 / 跨线程共享的代码**必须**有显式注释
- 注释里给的链接要是**永久**的（不要指向 issue #N — 会变）

---

## 五、Commit message 规范

格式（参考 Angular convention）：

```
<type>(<scope>): <subject>

<body>

<footer>
```

`<type>`:
- `feat` — 新功能
- `fix` — 修 bug
- `refactor` — 重构（不改变行为）
- `docs` — 文档
- `test` — 测试
- `chore` — 构建/工具/依赖

`<scope>`:
- `airplay` — AirPlay 接收
- `usb` — USB 采集
- `hid` / `ble-reverse` — 蓝牙 HID 反控
- `preview` / `render` — 预览渲染
- `audio` — 音频
- `ui` — 界面（ArkTS）
- `core` — 协议层（**不允许改 upstream 文件**）

`<subject>`:
- 中文，最多 50 字
- 不写句号
- "修「X 现象」的根因：Y" 这种格式优先

`<body>`:
- 解释**为什么**这么改（不止"改了什么"）
- 关联到上游 issue / PR（如有）
- 列出**自检**跑过的脚本与结果

`<footer>`:
- `Closes #N` / `Refs #N`（如有）

---

## 六、PR 流程

1. **Fork + 分支**：分支名格式 `<scope>/<short-desc>`（例：`ble-reverse/fix-gatt-write-no-rsp`）
2. **本地** 跑通 § 三的自检 + 跑通 § 二.2 的构建
3. **Commit** 按 § 五的格式
4. **PR 描述** 必填：
   - 关联 issue（`Fixes #N` 或 `Refs #N`）
   - 改动概要（一段话）
   - 自检截图（types 0 / alias 0 那两行）
   - 真机测试（iOS 版本、鸿蒙版本、复现路径）
   - **如有 UI 改动，附截图或录屏**
5. **Code review** 重点查：上游文件改动（§ 一.1）、自检清单（§ 一.2）、假成功（§ 一.3）

---

## 七、提 PR 前**自查**清单

- [ ] 没动任何上游文件（`cpp/Core/`、`cpp/types/libim_core/`、`third_party/`）
- [ ] `versionName` / `versionCode` 都递增了
- [ ] `CHANGELOG.md` 顶部加了一节
- [ ] `CHANGELOG_RELEASES` 常量同步了（按版本分组）
- [ ] `tools/check_arkts_types.py .` 0 错（警告仅 napi 28014）
- [ ] `tools/check_alias_narrowing.py .` 0 嫌
- [ ] 真机编译通过、跑通主流程
- [ ] 没塞 print / 没改函数行为 / 没动上游变量名
- [ ] commit message 符合 § 五
- [ ] PR 描述填全（§ 六.4）

---

## 八、风格与原则（哲学层）

- **先找能工作的参考实现对齐** — 别凭直觉改协议
- **同一维度恒有两字段** — 别只报一个数
- **"抛异常" = 未知** — 别把异常吞了假装没事
- **自洽推理 ≠ 证据** — 先核契约
- **只显示"最近一次结果"会吃掉证据** — 用只增不减的账本
- **断点 = 真问题** — 别用兜底掩盖

详细判据见 [`docs/移植说明.md`](docs/移植说明.md) 各章节。

---

_这份文件是开发者向。普通用户请看 [SUPPORT.md](SUPPORT.md)；安全/隐私问题请看 [SECURITY.md](SECURITY.md)。_