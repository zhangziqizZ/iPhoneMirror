// i18n.ets —— 运行时多语言（中 / 繁中(香港) / 英）。
//
// 设计要点：
//   · 字符串以「简体中文原文」作 key，查表返回当前语言的译文；查不到则原样返回中文。
//     —— 这样无需给每个字符串发明英文标识符，也天然向后兼容（新增中文串默认显示中文）。
//   · 响应式：t() 在 ArkUI 的 build() 期间读 AppStorage 的语言档位，组件据此建立联动，
//     切换语言时整树自动重渲染。无需逐个组件挂 @StorageLink。
//   · set_language() 同时调 setAppPreferredLanguage()，让系统层（权限说明、能力描述等
//     resources 里的串）也跟着切；译文不足时这些串仍走 resources 各自的 locale 文件。
//
// 旧版只有「界面语言」选择器却没有实际作用（on_language_changed 只写一句"当前语言不支持"），
// 本文件是它真正落地的机制。

import i18n from '@ohos.i18n';

/** 语言档位在 AppStorage 里的键（存的是 0..3 的索引，见 LANGUAGE_TAGS）。 */
export const LANG_INDEX_KEY: string = 'im.langIndex';

/** 0=跟随系统 1=简体 2=繁中(香港) 3=英文。 */
export const LANGUAGE_TAGS: string[] = ['system', 'zh-CN', 'zh-HK', 'en-US'];

/** 选项标签按语言分三套（选择器自身也要本地化）。 */
export const LANGUAGE_LABELS: Record<string, string[]> = {
  'zh-CN': ['跟随系统', '简体中文', '繁體中文（香港）', 'English'],
  'zh-HK': ['跟隨系統', '簡體中文', '繁體中文（香港）', 'English'],
  'en-US': ['Follow System', 'Simplified Chinese', 'Traditional Chinese (HK)', 'English'],
};

/**
 * 解析当前生效语言。
 * 档位 0（跟随系统）时读系统语言：含 zh 且带 hk/tw → zh-HK，含 zh 其它 → zh-CN，否则 en-US。
 *
 * ★ 系统语言解析结果必须缓存：t() 在每次整树重渲染里被调用成百上千次，
 *   i18n.System.getSystemLanguage() 是同步系统调用，不缓存的话「跟随系统」档
 *   每次重渲染都要打几百次系统调用 —— 这是切语言卡顿的来源之一。
 *   缓存只在 set_language(0)（改回跟随系统）时失效。
 */
let cached_system_lang: string = '';

function resolve_system_lang(): string {
  if (cached_system_lang !== '') {
    return cached_system_lang;
  }
  try {
    const sys: string = i18n.System.getSystemLanguage();
    const lower: string = (sys ?? '').toLowerCase();
    if (lower.startsWith('zh')) {
      cached_system_lang = (lower.includes('hk') || lower.includes('tw')) ? 'zh-HK' : 'zh-CN';
    } else {
      cached_system_lang = 'en-US';
    }
  } catch (e) {
    return 'zh-CN';   // 解析失败不缓存（下次再试），兜底简体
  }
  return cached_system_lang;
}

export function active_lang(): string {
  const idx: number = AppStorage.get<number>(LANG_INDEX_KEY) ?? 1;
  if (idx <= 0) {
    return resolve_system_lang();
  }
  return LANGUAGE_TAGS[idx] ?? 'zh-CN';
}

/** 简体中文 → 英文。占位符（%d/%s/{0}/·/×）原样保留。 */
const ZH2EN: Record<string, string> = {
  // ── DeviceViewModel ──
  '视频应用投屏': 'Video app casting',
  'AirPlay / DLNA 视频': 'AirPlay / DLNA video',
  '网络媒体投放': 'Network media cast',
  '正在投放视频': 'Video is being cast',
  '型号读取中': 'Reading model',
  '本地网络': 'Local network',
  'AirPlay 已连接': 'AirPlay connected',
  '未连接': 'Disconnected',
  'USB 已连接，等待 Apple 通道': 'USB connected; waiting for Apple channel',
  '已连接': 'Connected',
  '已配对，请解锁设备': 'Paired; unlock the device',
  '已连接并配对': 'Connected and paired',
  '设备连接异常': 'Device connection error',
  // ── About / Update / DeviceBinding / Startup / AppPrompt 等 ──
  '检测到当前视频画面持续为黑屏': 'The current video has remained black',
  '画面恢复后自动关闭': 'Closes when video returns',
  '有音频': 'Audio on',
  '无音频': 'No audio',
  '关闭': 'Close',
  '预览设备': 'Preview device',
  '继续': 'Continue',
  '开发者提示预览': 'Developer prompt preview',
  '检测到另一个 iPhoneMirror 程序正在运行。请选择要保留的窗口。': 'Another iPhoneMirror instance is currently running. Choose which window to keep.',
  '关闭其他窗口': 'Close other window',
  '关闭当前窗口': 'Close this window',
  'iPhoneMirror 无法启动': 'iPhoneMirror could not start',
  '诊断日志': 'Diagnostic log',
  '错误详情': 'Error details',
  '打开日志位置': 'Open log location',
  '以真实设备档案管理 USB、AirPlay 和 Bluetooth 身份绑定。': 'Manage USB, AirPlay, and Bluetooth identities for real device profiles.',
  '查看完整 Release': 'View full release',
  '当前版本': 'Current version',
  '最新版本': 'Latest version',
  '发布时间': 'Published',
  '稍后提醒': 'Remind me later',
  '立即更新': 'Update now',
  '低延迟 iPhone 屏幕投射、录制、直播与虚拟摄像头。': 'Low-latency iPhone mirroring, recording, streaming, and virtual camera output.',
  '更新状态': 'Update status',
  '可随时检查 GitHub Release 更新。': 'Check GitHub Releases for updates at any time.',
  '检查更新': 'Check for updates',
  '更新日志': 'Changelog',
  '许可证信息': 'License information',
  '关于': 'About',
  '更新设置': 'Update settings',
  '诊断': 'Diagnostics',
  '控制后台检查、自动下载、镜像加速和发布通道。': 'Control background checks, automatic downloads, mirror acceleration, and release channels.',
  '启动时检查更新': 'Check for updates at startup',
  '发现更新后自动开始下载': 'Start downloading automatically when an update is found',
  '自动选择最快更新下载线路': 'Automatically select the fastest update route',
  '提醒正式版更新': 'Notify me about stable releases',
  '提醒 Beta 预览版更新': 'Notify me about Beta preview releases',
  // ── 关于页「检查更新」的结果文案（1.0.45 真接入 GitHub Releases API）──
  '正在查询 GitHub Releases…': 'Querying GitHub Releases…',
  '检查中…': 'Checking…',
  '无法检查更新：': 'Unable to check for updates: ',
  '发现新版本': 'A new version is available',
  '预览版': 'Preview',
  '点「更新日志」去 GitHub 下载。': 'Open Changelog to download it from GitHub.',
  '已是最新：本机 ': 'Up to date: this device has ',
  '，GitHub 最新 ': ', latest on GitHub is ',
  '仓库 ': 'Repository ',
  ' 还没有发布任何 Release': ' has no published Release yet',
  '（本机 ': ' (this device: ',
  '日志位置': 'Log location',
  '打开日志目录': 'Open log folder',
  '清理日志和更新缓存': 'Clean logs and update cache',
  '实时日志  ·  Ctrl+L': 'Live log · Ctrl+L',
  '清空视图': 'Clear view',
  '日志视图已清空（不会删除磁盘日志）': 'Log view cleared (the log file was not deleted)',
  '正在等待蓝牙控制连接': 'Waiting for Bluetooth control',
  '设备列表中通常显示为：{0}': 'This PC usually appears in the device list as: {0}',
  '等待 HID 鼠标连接': 'Waiting for HID mouse connection',
  'iPhone：若再次出现配对提示窗口，点击“配对”。': 'iPhone: If another pairing prompt appears, tap Pair again.',
  '蓝牙控制无法启动': 'Bluetooth control could not start',
  '启动失败': 'Startup failed',
  '蓝牙控制需要刷新配对': 'Bluetooth control needs pairing refresh',
  '需要重新配对': 'Re-pair required',
  '我已重新配对': 'I have re-paired',
  '蓝牙反向控制已开启（实验）': 'Bluetooth reverse control enabled (Experimental)',
  '按 {0} 释放鼠标': 'Press {0} to release',
  '{0} 秒后自动关闭': 'Closes automatically in {0} seconds',
  '请确认准备工作后继续': 'Confirm the prerequisites before continuing',
  '启用无线控制前请确认': 'Before enabling wireless control',
  '启用有线控制前请确认': 'Before enabling wired control',
  '投屏未能继续': 'Mirroring could not continue',
  '反控未能继续': 'Reverse control could not continue',
  'USB 投屏配置未完成': 'USB mirroring setup incomplete',
  '投屏已停止': 'Mirroring stopped',
  '请检查设备和连接后重试': 'Check the device and connection, then retry',
  '请重新插拔数据线后重试': 'Reconnect the cable, then retry',
  '重启设备后可再次投屏': 'Restart the device before mirroring again',
  '请重启 iPhone 或 iPad 后再试。': 'Restart the iPhone or iPad, then try again.',
  '请保持设备解锁，重新插拔数据线后再试。': 'Keep the device unlocked, reconnect the cable, then try again.',
  '请停止投屏后重新开始；仍失败时重新连接设备。': 'Stop and start mirroring again. If it still fails, reconnect the device.',
  '只读预览': 'READ-ONLY PREVIEW',
  '工作区页面': 'Workspace pages',
  '快速切换主窗口中的所有工作区状态': 'Jump through every workspace state in the main window',
  '子窗口与弹窗': 'Child windows and dialogs',
  '打开现有窗口的安全预览；网络、设备和破坏性操作已隔离': 'Open safe previews; network, device, and destructive paths are isolated',
  '运行期参数': 'Runtime parameters',
  '参数仅影响当前进程，便于检查主题、缩放和窗口协调': 'Session-only controls for theme, scale, and window coordination',
  '窗口检查器': 'Window inspector',
  '主窗口透明度': 'Main window opacity',
  '主窗口置顶': 'Keep main window on top',
  '窗口预设': 'Window preset',
  '紧凑 1280×700': 'Compact 1280×700',
  '默认 1540×900': 'Default 1540×900',
  '最大化': 'Maximize',
  '重置参数': 'Reset parameters',
  '激活': 'Activate',
  '预览窗口已打开': 'Preview window opened',
  '打开预览失败': 'Preview failed',
  '参数已恢复默认值': 'Parameters restored to defaults',
  '版本': 'Version',
  '区域': 'Culture',
  '主题': 'Theme',
  '文字缩放': 'Text scale',
  '窗口数': 'Window count',
  '我的设备档案': 'My device profiles',
  '添加 AirPlay 设备档案': 'Add AirPlay device profile',
  '重命名档案': 'Rename profile',
  '删除档案': 'Delete profile',
  '选择设备档案': 'Select a device profile',
  '为此档案选择并管理三种连接身份。': 'Choose and manage the three connection identities for this profile.',
  '有线 USB': 'Wired USB',
  'AirPlay': 'AirPlay',
  'Bluetooth': 'Bluetooth',
  '绑定选择设备': 'Bind selected device',
  '连接设备': 'Connect device',
  '未绑定': 'Unbound',
  '已绑定 · 已连接': 'Bound · Connected',
  '已绑定 · 当前镜像': 'Bound · Currently mirrored',
  '已绑定 · 当前不可用': 'Bound · Currently unavailable',
  '已绑定 · 已断开': 'Bound · Disconnected',
  '型号信息待获取': 'Model information unavailable',
  '未命名设备': 'Unnamed device',
  '无法创建设备档案。': 'Could not create the device profile.',
  '输入设备档案名称': 'Enter a device profile name',
  '应用': 'Apply',
  '请先为该档案绑定 USB 或 AirPlay 设备。': 'Bind a USB or AirPlay device to this profile first.',
  '无法启动 Bluetooth HID 连接。请确认电脑蓝牙已开启。': 'Could not start the Bluetooth HID connection. Make sure Bluetooth is enabled on this computer.',
  '设备身份不能为空。': 'A device identity is required.',
  '该设备身份已经绑定到设备档案。': 'This device identity is already bound to a device profile.',
  '该设备身份已绑定到另一台设备档案。': 'This device identity is already bound to another device profile.',
  '设备档案不存在。': 'The device profile was not found.',
  '检测到的设备型号不一致，无法绑定。': 'The detected device model does not match; it cannot be bound.',
  '设备型号一致，需要用户确认。': 'The device model matches, but user confirmation is required.',
  '无法自动验证设备型号，需要用户确认。': 'The device model could not be verified automatically; user confirmation is required.',
  '无法保存 Bluetooth 设备绑定。': 'Could not save the Bluetooth device binding.',
  // ── AboutWindow ──
  '最新': 'Latest',
  '版本更新': "What's New",
  '清理完成：删除 %d 个文件，释放 %s；%d 个正在使用或无权限的文件已跳过。': 'Cleanup complete: deleted %d files, freed %s; skipped %d files in use or without permission.',
  '清理失败：%s': 'Cleanup failed: %s',
  // ── BluetoothClientBinding ──
  '请选择与“{0}”对应的蓝牙手机': 'Choose the Bluetooth phone for “{0}”',
  '解除绑定': 'Unbind',
  '刷新蓝牙客户端': 'Refresh Bluetooth clients',
  '确认绑定': 'Confirm binding',
  '取消': 'Cancel',
  '绑定蓝牙手机': 'Bind Bluetooth phone',
  '已刷新：{0} 个蓝牙客户端': 'Refreshed: {0} Bluetooth clients',
  '已清除「{0}」的绑定标记（本移植未做持久化，重启后回到原状）': 'Cleared binding marker for "{0}" (not persisted in this port; reverts after restart)',
  '该条目当前没有绑定标记可清除。': 'This entry has no binding marker to clear.',
  // ── BluetoothConnection ──
  '等待 Bluetooth HID 连接': 'Waiting for Bluetooth HID connection',
  '本设备正在广播 Bluetooth HID 设备': 'This device is broadcasting a Bluetooth HID device',
  '等待设备订阅 HID 服务': 'Waiting for device to subscribe to HID service',
  '下一步': 'Next',
  // ── BluetoothControlNotice ──
  '反向控制期间本机光标会隐藏。': 'The local cursor is hidden during reverse control.',
  // ── DeviceBinding ──
  '确认删除？': 'Confirm deletion?',
  '（没有可选项）': '(no options available)',
  // ── InstanceConflict ──
  '仍有 %d 个 iPhoneMirror 实例未能关闭。': '%d iPhoneMirror instances could not be closed.',
  // ── ShortcutSettings ──
  'Ctrl': 'Ctrl',
  'Alt': 'Alt',
  'Shift': 'Shift',
  '右键': 'Right mouse button',
  '中键': 'Middle mouse button',
  // ── 主窗关键串（Index.ets）──
  '投屏': 'Mirroring',
  '投屏来源': 'Mirroring sources',
  '设置': 'Settings',
  '设备绑定器': 'Device binder',
  '界面语言': 'Interface language',
  '应用主题': 'Application theme',
  '应用模式': 'Application mode',
  '开始投屏': 'Start mirroring',
  '停止投屏': 'Stop mirroring',
  '刷新画面': 'Refresh frame',
  '独立窗口': 'Preview window',
  '调节画面': 'Adjust image',
  '全屏预览': 'Full-screen preview',
  '录制与推流': 'Recording and streaming',
  '敬请期待': 'Coming Soon',

  // ── Index 导航 / 页脚 / 选择器（补充）──
  '投屏控制': 'Mirroring controls',
  '选择投屏来源': 'Choose a mirroring source',
  '投屏设置': 'Projection settings',
  '管理真实设备的 USB、AirPlay 和 Bluetooth 身份绑定': 'Manage USB, AirPlay, and Bluetooth identities for real devices',
  '输出设置': 'Output settings',
  '驱动管理': 'Driver manager',
  '关于与更新': 'About and updates',
  '输出': 'Output',
  '驱动': 'Drivers',
  '高级设置': 'Advanced settings',
  '开发者工具': 'Developer tools',
  '该功能': 'This feature',
  '鸿蒙版尚未实现。': 'Not yet implemented on HarmonyOS.',
  '反控接管时收起指针': 'Hide local cursor while controlling',
  // ── 状态栏（StatsPanel，对齐上游 Strings.xaml 的 *Label）──
  '分辨率': 'Resolution',
  '帧率': 'Frame rate',
  '延迟': 'Latency',
  '端到端': 'End to end',
  '音频': 'Audio',
};

/** 简体中文 → 繁體中文（香港）。 */
const ZH2HK: Record<string, string> = {
  // ── DeviceViewModel ──
  '视频应用投屏': '影片 App AirPlay 播放',
  'AirPlay / DLNA 视频': 'AirPlay / DLNA 影片投放',
  '网络媒体投放': '網絡媒體投放',
  '正在投放视频': '正在投放影片',
  '型号读取中': '型號讀取中',
  '本地网络': '本機網絡',
  'AirPlay 已连接': 'AirPlay 已連接',
  '未连接': '未連接',
  'USB 已连接，等待 Apple 通道': 'USB 已連接，等待 Apple 通道',
  '已连接': '已連接',
  '已配对，请解锁设备': '已配對，請解鎖裝置',
  '已连接并配对': '已連接並配對',
  '设备连接异常': '裝置連接異常',
  // ── About / Update / DeviceBinding / Startup / AppPrompt 等 ──
  '检测到当前视频画面持续为黑屏': '偵測到目前影片畫面持續為黑畫面',
  '画面恢复后自动关闭': '畫面恢復後自動關閉',
  '有音频': '有音訊',
  '无音频': '無音訊',
  '关闭': '關閉',
  '预览设备': '預覽裝置',
  '继续': '繼續',
  '开发者提示预览': '開發者提示預覽',
  '检测到另一个 iPhoneMirror 程序正在运行。请选择要保留的窗口。': '偵測到另一個 iPhoneMirror 程式正在執行。請選擇要保留的視窗。',
  '关闭其他窗口': '關閉其他視窗',
  '关闭当前窗口': '關閉目前視窗',
  'iPhoneMirror 无法启动': 'iPhoneMirror 無法啟動',
  '诊断日志': '診斷記錄',
  '错误详情': '錯誤詳細資料',
  '打开日志位置': '開啟記錄位置',
  '以真实设备档案管理 USB、AirPlay 和 Bluetooth 身份绑定。': '以真實裝置檔案管理 USB、AirPlay 和 Bluetooth 身份綁定。',
  '查看完整 Release': '查看完整 Release',
  '当前版本': '目前版本',
  '最新版本': '最新版本',
  '发布时间': '發佈時間',
  '稍后提醒': '稍後提醒',
  '立即更新': '立即更新',
  '低延迟 iPhone 屏幕投射、录制、直播与虚拟摄像头。': '低延遲 iPhone 螢幕投射、錄製、直播與虛擬攝影機。',
  '更新状态': '更新狀態',
  '可随时检查 GitHub Release 更新。': '可隨時檢查 GitHub Release 更新。',
  '检查更新': '檢查更新',
  '更新日志': '更新記錄',
  '许可证信息': '許可證資訊',
  '关于': '關於',
  '更新设置': '更新設定',
  '诊断': '診斷',
  '控制后台检查、自动下载、镜像加速和发布通道。': '控制背景更新檢查、自動下載、鏡像加速和發佈通道。',
  '启动时检查更新': '啟動時檢查更新',
  '发现更新后自动开始下载': '發現更新後自動開始下載',
  '自动选择最快更新下载线路': '自動選擇最快更新下載線路',
  '提醒正式版更新': '提醒正式版更新',
  '提醒 Beta 预览版更新': '提醒 Beta 預覽版更新',
  '正在查询 GitHub Releases…': '正在查詢 GitHub Releases…',
  '检查中…': '檢查中…',
  '无法检查更新：': '無法檢查更新：',
  '发现新版本': '發現新版本',
  '预览版': '預覽版',
  '点「更新日志」去 GitHub 下载。': '點「更新日誌」去 GitHub 下載。',
  '已是最新：本机 ': '已是最新：本機 ',
  '，GitHub 最新 ': '，GitHub 最新 ',
  '仓库 ': '倉庫 ',
  ' 还没有发布任何 Release': ' 還沒有發布任何 Release',
  '（本机 ': '（本機 ',
  '日志位置': '記錄位置',
  '打开日志目录': '開啟記錄檔位置',
  '清理日志和更新缓存': '清理記錄和更新快取',
  '实时日志  ·  Ctrl+L': '即時記錄 · Ctrl+L',
  '清空视图': '清除檢視',
  '日志视图已清空（不会删除磁盘日志）': '記錄檢視已清除（不會刪除磁碟上的記錄檔）',
  '正在等待蓝牙控制连接': '正在等待藍牙控制連接',
  '设备列表中通常显示为：{0}': '裝置清單中通常顯示為：{0}',
  '等待 HID 鼠标连接': '等待 HID 滑鼠連接',
  'iPhone：若再次出现配对提示窗口，点击“配对”。': 'iPhone：若再次出現配對提示視窗，點選「配對」。',
  '蓝牙控制无法启动': '藍牙控制無法啟動',
  '启动失败': '啟動失敗',
  '蓝牙控制需要刷新配对': '藍牙控制需要重新配對',
  '需要重新配对': '需要重新配對',
  '我已重新配对': '我已重新配對',
  '蓝牙反向控制已开启（实验）': '藍牙反向控制已開啟（實驗）',
  '按 {0} 释放鼠标': '按 {0} 釋放滑鼠',
  '{0} 秒后自动关闭': '{0} 秒後自動關閉',
  '请确认准备工作后继续': '請確認準備工作後繼續',
  '启用无线控制前请确认': '啟用無線控制前請確認',
  '启用有线控制前请确认': '啟用有線控制前請確認',
  '投屏未能继续': '螢幕鏡像未能繼續',
  '反控未能继续': '反控未能繼續',
  'USB 投屏配置未完成': 'USB 螢幕鏡像設定未完成',
  '投屏已停止': '螢幕鏡像已停止',
  '请检查设备和连接后重试': '請檢查裝置和連線後重試',
  '请重新插拔数据线后重试': '請重新插拔傳輸線後重試',
  '重启设备后可再次投屏': '重新啟動裝置後可再次螢幕鏡像',
  '请重启 iPhone 或 iPad 后再试。': '請重新啟動 iPhone 或 iPad 後再試。',
  '请保持设备解锁，重新插拔数据线后再试。': '請保持裝置解鎖，重新插拔傳輸線後再試。',
  '请停止投屏后重新开始；仍失败时重新连接设备。': '請停止螢幕鏡像後重新開始；仍失敗時重新連接裝置。',
  '只读预览': '唯讀預覽',
  '工作区页面': '工作區頁面',
  '快速切换主窗口中的所有工作区状态': '快速切換主視窗的所有工作區狀態',
  '子窗口与弹窗': '子視窗與對話方塊',
  '打开现有窗口的安全预览；网络、设备和破坏性操作已隔离': '開啟安全預覽；網絡、裝置和破壞性操作已隔離',
  '运行期参数': '執行階段參數',
  '参数仅影响当前进程，便于检查主题、缩放和窗口协调': '只影響目前工作階段，用於檢查主題、縮放和視窗協調',
  '窗口检查器': '視窗檢查器',
  '主窗口透明度': '主視窗透明度',
  '主窗口置顶': '主視窗置頂',
  '窗口预设': '視窗預設',
  '紧凑 1280×700': '緊湊 1280×700',
  '默认 1540×900': '預設 1540×900',
  '最大化': '最大化',
  '重置参数': '重設參數',
  '激活': '啟用',
  '预览窗口已打开': '預覽視窗已開啟',
  '打开预览失败': '開啟預覽失敗',
  '参数已恢复默认值': '參數已還原為預設值',
  '版本': '版本',
  '区域': '地區',
  '主题': '主題',
  '文字缩放': '文字縮放',
  '窗口数': '視窗數量',
  '我的设备档案': '我的裝置檔案',
  '添加 AirPlay 设备档案': '新增 AirPlay 裝置檔案',
  '重命名档案': '重新命名檔案',
  '删除档案': '刪除檔案',
  '选择设备档案': '選擇裝置檔案',
  '为此档案选择并管理三种连接身份。': '為此檔案選擇並管理三種連線身份。',
  '有线 USB': '有線 USB',
  'AirPlay': 'AirPlay',
  'Bluetooth': 'Bluetooth',
  '绑定选择设备': '綁定所選裝置',
  '连接设备': '連接裝置',
  '未绑定': '未繫結',
  '已绑定 · 已连接': '已綁定 · 已連接',
  '已绑定 · 当前镜像': '已綁定 · 目前鏡像',
  '已绑定 · 当前不可用': '已綁定 · 目前不可用',
  '已绑定 · 已断开': '已綁定 · 已中斷連線',
  '型号信息待获取': '型號資料待取得',
  '未命名设备': '未命名裝置',
  '无法创建设备档案。': '無法建立裝置檔案。',
  '输入设备档案名称': '輸入裝置檔案名稱',
  '应用': '套用',
  '请先为该档案绑定 USB 或 AirPlay 设备。': '請先為此檔案綁定 USB 或 AirPlay 裝置。',
  '无法启动 Bluetooth HID 连接。请确认电脑蓝牙已开启。': '無法啟動 Bluetooth HID 連線。請確認電腦藍牙已開啟。',
  '设备身份不能为空。': '裝置身份不可為空。',
  '该设备身份已经绑定到设备档案。': '此裝置身份已綁定到裝置檔案。',
  '该设备身份已绑定到另一台设备档案。': '此裝置身份已綁定到另一個裝置檔案。',
  '设备档案不存在。': '找不到裝置檔案。',
  '检测到的设备型号不一致，无法绑定。': '偵測到的裝置型號不一致，無法綁定。',
  '设备型号一致，需要用户确认。': '裝置型號一致，需要用戶確認。',
  '无法自动验证设备型号，需要用户确认。': '無法自動驗證裝置型號，需要用戶確認。',
  '无法保存 Bluetooth 设备绑定。': '無法儲存 Bluetooth 裝置綁定。',
  // ── AboutWindow ──
  '最新': '最新',
  '版本更新': '版本更新',
  '清理完成：删除 %d 个文件，释放 %s；%d 个正在使用或无权限的文件已跳过。': '清理完成：刪除 %d 個文件，釋放 %s；%d 個正在使用或無權限的文件已跳過。',
  '清理失败：%s': '清理失敗：%s',
  // ── BluetoothClientBinding ──
  '请选择与“{0}”对应的蓝牙手机': '請選擇與「{0}」對應的藍牙手機',
  '解除绑定': '解除綁定',
  '刷新蓝牙客户端': '重新整理藍牙用戶端',
  '确认绑定': '確認綁定',
  '取消': '取消',
  '绑定蓝牙手机': '綁定藍牙手機',
  '已刷新：{0} 个蓝牙客户端': '已刷新：{0} 個藍牙客戶端',
  '已清除「{0}」的绑定标记（本移植未做持久化，重启后回到原状）': '已清除「{0}」的綁定標記（本移植未做持久化，重啟後回到原狀）',
  '该条目当前没有绑定标记可清除。': '該條目當前沒有綁定標記可清除。',
  // ── BluetoothConnection ──
  '等待 Bluetooth HID 连接': '等待 Bluetooth HID 連線',
  '本设备正在广播 Bluetooth HID 设备': '本設備正在廣播 Bluetooth HID 設備',
  '等待设备订阅 HID 服务': '等待裝置訂閱 HID 服務',
  '下一步': '下一步',
  // ── BluetoothControlNotice ──
  '反向控制期间本机光标会隐藏。': '反向控制期間本機光標會隱藏。',
  // ── DeviceBinding ──
  '确认删除？': '確認刪除？',
  '（没有可选项）': '（沒有可選項）',
  // ── InstanceConflict ──
  '仍有 %d 个 iPhoneMirror 实例未能关闭。': '仍有 %d 個 iPhoneMirror 實例未能關閉。',
  // ── ShortcutSettings ──
  'Ctrl': 'Ctrl',
  'Alt': 'Alt',
  'Shift': 'Shift',
  '右键': '右鍵',
  '中键': '中鍵',
  // ── 主窗关键串（Index.ets）──
  '投屏': '螢幕鏡像',
  '投屏来源': '螢幕鏡像來源',
  '设置': '設定',
  '设备绑定器': '裝置綁定器',
  '界面语言': '介面語言',
  '应用主题': '應用程式主題',
  '应用模式': '應用模式',
  '开始投屏': '開始螢幕鏡像',
  '停止投屏': '停止螢幕鏡像',
  '刷新画面': '重新整理畫面',
  '独立窗口': '獨立視窗',
  '调节画面': '調節畫面',
  '全屏预览': '全螢幕預覽',
  '录制与推流': '錄製與串流',
  '敬请期待': '敬請期待',

  // ── Index 导航 / 页脚 / 选择器（补充）──
  '投屏控制': '螢幕鏡像控制',
  '选择投屏来源': '選擇螢幕鏡像來源',
  '投屏设置': '螢幕鏡像設定',
  '管理真实设备的 USB、AirPlay 和 Bluetooth 身份绑定': '管理真實裝置的 USB、AirPlay 和 Bluetooth 身份綁定',
  '输出设置': '輸出設定',
  '驱动管理': '驅動程式管理',
  '关于与更新': '關於與更新',
  '输出': '輸出',
  '驱动': '驅動程式',
  '高级设置': '進階設定',
  '开发者工具': '開發者工具',
  '该功能': '該功能',
  '鸿蒙版尚未实现。': '鴻蒙版尚未實現。',
  '反控接管时收起指针': '反控接管時收起指標',
  // ── 状态栏（StatsPanel，对齐上游 Strings.xaml 的 *Label）──
  '分辨率': '解像度',
  '帧率': '幀率',
  '延迟': '延遲',
  '端到端': '端對端',
  '音频': '音訊',
};

/**
 * 主翻译函数。build() 期间调用即建立与语言档位的联动，切语言时所在组件自动重渲染。
 * @param zh 简体中文原文（同时作为 zh-CN 档与查表失败时的兜底）
 */
export function t(zh: string): string {
  const lang: string = active_lang();
  if (lang === 'zh-CN') {
    return zh;
  }
  const dict: Record<string, string> = (lang === 'zh-HK') ? ZH2HK : ZH2EN;
  return dict[zh] ?? zh;
}

/**
 * 切换语言档位。
 * @param index 0=跟随系统 1=简体 2=繁中(香港) 3=英文
 *
 * ★ 卡顿修复（1.0.46）：AppStorage 写入后下一帧就是整树重渲染（这是语言切换
 *   必要的成本），此时不能在同一个 onSelect 回调里再同步干重活 ——
 *   i18n.System.setAppPreferredLanguage() 是同步系统调用、还会触发系统层资源
 *   重载，放在这里会把刚触发的重渲染卡在半路。延后一拍再执行，界面先切。
 */
export function set_language(index: number): void {
  AppStorage.setOrCreate<number>(LANG_INDEX_KEY, index);
  const tag: string = LANGUAGE_TAGS[index];
  if (tag && tag !== 'system') {
    setTimeout((): void => {
      try {
        // ★ 静态方法：i18n.System.setAppPreferredLanguage（@since 20），不是 context 上的方法。
        //   失败不影响运行时 t() 翻译（resources 里的串仍走各自 locale 文件），吞掉避免崩溃。
        i18n.System.setAppPreferredLanguage(tag);
      } catch (e) {
        // 系统层切换失败不影响运行时 t() 翻译；吞掉避免崩溃。
      }
    }, 50);
  } else {
    cached_system_lang = '';   // 改回跟随系统：下次 t() 重新解析一次系统语言
  }
}
