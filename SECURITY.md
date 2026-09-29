# SECURITY.md · 安全与隐私

> **含敏感信息的报告请勿公开提 issue** — 见 § 二。
> 本文件说明：哪些是"敏感信息"，为什么不能公开，以及怎么私密上报。

---

## 一、本项目涉及哪些"敏感信息"

iPhone 投屏涉及多类**高敏感**的个人 / 设备 / 凭据数据。**任何**反馈（含 issue、
discussion、PR 评论）都不应包含下面任何一项：

| 类别 | 例 | 为什么敏感 |
|---|---|---|
| **UDID** | iPhone 的 40 位唯一标识符 | 配对身份识别，配合其他凭据可被未授权使用 |
| **ECID** | Exclusive Chip ID（32 位十六进制） | 同上 |
| **设备序列号** | iPhone 序列号、鸿蒙电脑序列号 | 设备物理标识 |
| **Wi-Fi 密码** | 家/公司路由器的密码 | 直白隐私 |
| **mDNS 抓包内容** | 局域网 mDNS 查询与应答 | 含设备身份 + 局域网拓扑 |
| **USB 抓包** | pcap / logcat 含 USB 流量 | Apple 私有协议细节，被分析可能用于 0day |
| **蓝牙配对记录** | bond state / LinkKey / IRK / CSRK | 解密链路，可能用于中间人 |
| **AirPlay 配对凭据** | 持久化 seed（若已实现）/ 临时 PIN | 解密 RTP 流 |
| **解锁密码 / Apple ID** | 任何账户信息 | 显然 |
| **可识别个人身份的截图** | 含联系人 / 短信 / 通话记录 | 显然 |

---

## 二、怎么私密上报

GitHub 提供**私密漏洞报告**（Security Advisories）功能，本仓库已启用。
请走下列路径之一：

1. **本仓库 → Security tab → "Report a vulnerability"**（推荐）
2. 或发邮件到 `<security@your-domain>`（如该邮箱已配置）

**不要**：
- 在公开 issue / discussion / PR 评论里贴上面的任何一类
- 在 commit message 里贴
- 在截图 / 录屏里露出（即使"打码"也可能被还原）

---

## 三、如果你**不小心**公开了敏感信息

1. 立刻编辑 issue / 评论，把内容去掉
2. 让 PR 处于 draft / 撤销（git push --force 一次）
3. 在私密渠道报告 — 我们会处理剩余工作（撤 commit 历史等）
4. **对 Apple 私有协议 / 凭据**：考虑**旋转**（rotate）相关凭据 ——
   蓝牙 LinkKey 重置需在两端都"忘记此设备"再配对；AirPlay 持久化
   seed 重置需重启应用（当前实现每次重启换新）。

---

## 四、本项目自身的安全模型

- **不收集任何遥测**：本应用不向外部服务器发送任何数据
- **不联网**（除 AirPlay mDNS 多播、AppGallery 应用市场）：iPhone 屏幕内容
  **只在本地回环上传输**，不上云
- **GPL-3.0**：所有源代码公开、可审计
- **第三方组件**：详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) ——
  fdk-aac (Fraunhofer)、libplist、libxml2 等的许可与版权信息

---

## 五、安全相关的已知限制

- **AppGallery 上架**会让本应用暴露在更广攻击面下 ——
  审核机制无法保证没有改包。请从**官方渠道**下载本应用的安装包
  （GitHub Releases → AppGallery → 官网）。
- **鸿蒙 USB DDK 权限**：首次插入 iPhone 时会弹系统授权。
  任何时刻应用都只能访问**用户授权过的** USB 设备。
- **蓝牙权限**：ACCESS_BLUETOOTH 是 `user_grant`，
  没弹过窗的设备**永远不能被访问**。
- **多设备并存**：同时连两台 iPhone 时，各自的 GATT 服务和 HID
  是相互隔离的；一台出问题不会污染另一台。

---

## 六、致谢

报告安全问题的研究者请联系我们 ——
我们会在修复后致谢（除非你希望匿名）。

---

_这份文件只讲安全与隐私。普通问题反馈请看 [SUPPORT.md](SUPPORT.md)；开发者向请看 [CONTRIBUTING.md](CONTRIBUTING.md)。_