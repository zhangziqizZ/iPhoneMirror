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
 */
export function active_lang(): string {
  const idx: number = AppStorage.get<number>(LANG_INDEX_KEY) ?? 1;
  if (idx <= 0) {
    try {
      const sys: string = i18n.System.getSystemLanguage();
      const lower: string = (sys ?? '').toLowerCase();
      if (lower.startsWith('zh')) {
        return (lower.includes('hk') || lower.includes('tw')) ? 'zh-HK' : 'zh-CN';
      }
      return 'en-US';
    } catch (e) {
      return 'zh-CN';
    }
  }
  return LANGUAGE_TAGS[idx] ?? 'zh-CN';
}

/** 简体中文 → 英文。占位符（%d/%s/{0}/·/×）原样保留。 */
const ZH2EN: Record<string, string> = {
  // ── DeviceViewModel ──
  '视频应用投屏': 'Video App Casting',
  'AirPlay / DLNA 视频': 'AirPlay / DLNA Video',
  '网络媒体投放': 'Network Media Casting',
  '正在投放视频': 'Casting video',
  '型号读取中': 'Reading model',
  '本地网络': 'Local Network',
  'AirPlay 已连接': 'AirPlay Connected',
  '未连接': 'Disconnected',
  'USB 已连接，等待 Apple 通道': 'USB connected, waiting for Apple channel',
  '已连接': 'Connected',
  '已配对，请解锁设备': 'Paired, please unlock device',
  '已连接并配对': 'Connected and paired',
  '设备连接异常': 'Device connection error',
  // ── About / Update / DeviceBinding / Startup / AppPrompt 等 ──
  '检测到当前视频画面持续为黑屏': 'Current video stays black',
  '画面恢复后自动关闭': 'Auto-closes after video recovers',
  '有音频': 'Audio',
  '无音频': 'No Audio',
  '关闭': 'Close',
  '预览设备': 'Preview Device',
  '继续': 'Continue',
  '开发者提示预览': 'Developer Preview Prompt',
  '检测到另一个 iPhoneMirror 程序正在运行。请选择要保留的窗口。': 'Another iPhoneMirror instance is running. Choose the window to keep.',
  '关闭其他窗口': 'Close Other Windows',
  '关闭当前窗口': 'Close Current Window',
  'iPhoneMirror 无法启动': 'iPhoneMirror failed to start',
  '诊断日志': 'Diagnostics Log',
  '错误详情': 'Error Details',
  '打开日志位置': 'Open Log Location',
  '以真实设备档案管理 USB、AirPlay 和 Bluetooth 身份绑定。': 'Manage USB, AirPlay and Bluetooth identities with real device profiles.',
  '查看完整 Release': 'View Full Release',
  '当前版本': 'Current Version',
  '最新版本': 'Latest Version',
  '发布时间': 'Published',
  '稍后提醒': 'Remind Later',
  '立即更新': 'Update Now',
  '低延迟 iPhone 屏幕投射、录制、直播与虚拟摄像头。': 'Low-latency iPhone screen mirroring, recording, streaming and virtual camera.',
  '更新状态': 'Update Status',
  '可随时检查 GitHub Release 更新。': 'You can check GitHub Release for updates anytime.',
  '检查更新': 'Check for Updates',
  '更新日志': 'Changelog',
  '许可证信息': 'License Information',
  '关于': 'About',
  '更新设置': 'Update Settings',
  '诊断': 'Diagnostics',
  '控制后台检查、自动下载、镜像加速和发布通道。': 'Controls background checks, auto-download, mirror acceleration and release channel.',
  '启动时检查更新': 'Check for updates on startup',
  '发现更新后自动开始下载': 'Auto-download when an update is found',
  '自动选择最快更新下载线路': 'Auto-select the fastest download mirror',
  '提醒正式版更新': 'Notify for stable releases',
  '提醒 Beta 预览版更新': 'Notify for beta previews',
  '日志位置': 'Log Location',
  '打开日志目录': 'Open Log Folder',
  '清理日志和更新缓存': 'Clean Logs and Update Cache',
  '实时日志  ·  Ctrl+L': 'Live Log  ·  Ctrl+L',
  '清空视图': 'Clear View',
  '日志视图已清空（不会删除磁盘日志）': 'Log view cleared (disk logs are not deleted)',
  '正在等待蓝牙控制连接': 'Waiting for Bluetooth control connection',
  '设备列表中通常显示为：{0}': 'Usually shown in the device list as: {0}',
  '等待 HID 鼠标连接': 'Waiting for HID mouse connection',
  'iPhone：若再次出现配对提示窗口，点击“配对”。': 'iPhone: if the pairing prompt reappears, tap "Pair".',
  '蓝牙控制无法启动': 'Bluetooth control cannot start',
  '启动失败': 'Startup Failed',
  '蓝牙控制需要刷新配对': 'Bluetooth control needs re-pairing',
  '需要重新配对': 'Re-pairing required',
  '我已重新配对': 'I have re-paired',
  '蓝牙反向控制已开启（实验）': 'Bluetooth reverse control enabled (Experimental)',
  '按 {0} 释放鼠标': 'Press {0} to release the mouse',
  '{0} 秒后自动关闭': 'Auto-closes in {0}s',
  '请确认准备工作后继续': 'Confirm the preparation steps before continuing',
  '启用无线控制前请确认': 'Confirm before enabling wireless control',
  '启用有线控制前请确认': 'Confirm before enabling wired control',
  '投屏未能继续': 'Mirroring could not continue',
  '反控未能继续': 'Reverse control could not continue',
  'USB 投屏配置未完成': 'USB mirroring not configured',
  '投屏已停止': 'Mirroring stopped',
  '请检查设备和连接后重试': 'Check the device and connection, then retry',
  '请重新插拔数据线后重试': 'Re-plug the cable and retry',
  '重启设备后可再次投屏': 'Restart the device to mirror again',
  '请重启 iPhone 或 iPad 后再试。': 'Restart your iPhone or iPad and try again.',
  '请保持设备解锁，重新插拔数据线后再试。': 'Keep the device unlocked, re-plug the cable and try again.',
  '请停止投屏后重新开始；仍失败时重新连接设备。': 'Stop mirroring and start again; if it still fails, reconnect the device.',
  '只读预览': 'Read-only Preview',
  '工作区页面': 'Workspace Pages',
  '快速切换主窗口中的所有工作区状态': 'Quickly switch all workspace states in the main window',
  '子窗口与弹窗': 'Subwindows & Dialogs',
  '打开现有窗口的安全预览；网络、设备和破坏性操作已隔离': 'Safe preview of existing windows; network, device and destructive actions are isolated',
  '运行期参数': 'Runtime Parameters',
  '参数仅影响当前进程，便于检查主题、缩放和窗口协调': 'Parameters affect only the current process, for inspecting theme, scaling and window coordination',
  '窗口检查器': 'Window Inspector',
  '主窗口透明度': 'Main Window Opacity',
  '主窗口置顶': 'Main Window Always on Top',
  '窗口预设': 'Window Preset',
  '紧凑 1280×700': 'Compact 1280×700',
  '默认 1540×900': 'Default 1540×900',
  '最大化': 'Maximize',
  '重置参数': 'Reset Parameters',
  '激活': 'Activate',
  '预览窗口已打开': 'Preview window opened',
  '打开预览失败': 'Failed to open preview',
  '参数已恢复默认值': 'Parameters restored to defaults',
  '版本': 'Version',
  '区域': 'Region',
  '主题': 'Theme',
  '文字缩放': 'Text Scaling',
  '窗口数': 'Window Count',
  '我的设备档案': 'My Device Profiles',
  '添加 AirPlay 设备档案': 'Add AirPlay Device Profile',
  '重命名档案': 'Rename Profile',
  '删除档案': 'Delete Profile',
  '选择设备档案': 'Select Device Profile',
  '为此档案选择并管理三种连接身份。': 'Select and manage the three connection identities for this profile.',
  '有线 USB': 'Wired USB',
  'AirPlay': 'AirPlay',
  'Bluetooth': 'Bluetooth',
  '绑定选择设备': 'Bind Selected Device',
  '连接设备': 'Connect Device',
  '未绑定': 'Unbound',
  '已绑定 · 已连接': 'Bound · Connected',
  '已绑定 · 当前镜像': 'Bound · Mirroring',
  '已绑定 · 当前不可用': 'Bound · Unavailable',
  '已绑定 · 已断开': 'Bound · Disconnected',
  '型号信息待获取': 'Model info pending',
  '未命名设备': 'Unnamed Device',
  '无法创建设备档案。': 'Failed to create device profile.',
  '输入设备档案名称': 'Enter device profile name',
  '应用': 'Apply',
  '请先为该档案绑定 USB 或 AirPlay 设备。': 'Bind a USB or AirPlay device to this profile first.',
  '无法启动 Bluetooth HID 连接。请确认电脑蓝牙已开启。': 'Cannot start Bluetooth HID connection. Make sure Bluetooth is enabled on this PC.',
  '设备身份不能为空。': 'Device identity cannot be empty.',
  '该设备身份已经绑定到设备档案。': 'This device identity is already bound to a profile.',
  '该设备身份已绑定到另一台设备档案。': 'This device identity is already bound to another profile.',
  '设备档案不存在。': 'The device profile does not exist.',
  '检测到的设备型号不一致，无法绑定。': 'Detected device models differ; cannot bind.',
  '设备型号一致，需要用户确认。': 'Device models match; user confirmation required.',
  '无法自动验证设备型号，需要用户确认。': 'Cannot auto-verify the device model; user confirmation required.',
  '无法保存 Bluetooth 设备绑定。': 'Failed to save Bluetooth device binding.',
  // ── AboutWindow ──
  '最新': 'Latest',
  '版本更新': "What's New",
  '清理完成：删除 %d 个文件，释放 %s；%d 个正在使用或无权限的文件已跳过。': 'Cleanup complete: deleted %d files, freed %s; skipped %d files in use or without permission.',
  '清理失败：%s': 'Cleanup failed: %s',
  // ── BluetoothClientBinding ──
  '请选择与“{0}”对应的蓝牙手机': 'Select the Bluetooth phone corresponding to "{0}"',
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
  '右键': 'Right Button',
  '中键': 'Middle Button',
  // ── 主窗关键串（Index.ets）──
  '投屏': 'Screen Mirroring',
  '投屏来源': 'Mirroring Source',
  '设置': 'Settings',
  '设备绑定器': 'Device Binder',
  '界面语言': 'Interface Language',
  '应用主题': 'App Theme',
  '应用模式': 'App Mode',
  '开始投屏': 'Start Mirroring',
  '停止投屏': 'Stop Mirroring',
  '刷新画面': 'Refresh Screen',
  '独立窗口': 'Standalone Window',
  '调节画面': 'Adjust Screen',
  '全屏预览': 'Fullscreen Preview',
  '录制与推流': 'Record & Stream',
  '敬请期待': 'Coming Soon',

  // ── Index 导航 / 页脚 / 选择器（补充）──
  '投屏控制': 'Mirroring',
  '选择投屏来源': 'Choose a source',
  '投屏设置': 'Mirroring settings',
  '管理真实设备的 USB、AirPlay 和 Bluetooth 身份绑定': 'Manage USB, AirPlay and Bluetooth identities of real devices',
  '输出设置': 'Output settings',
  '驱动管理': 'Driver management',
  '关于与更新': 'About & Updates',
  '输出': 'Output',
  '驱动': 'Driver',
  '高级设置': 'Advanced',
  '开发者工具': 'Developer Tools',
  '该功能': 'This feature',
  '鸿蒙版尚未实现。': 'Not yet implemented on HarmonyOS.',
  '反控接管时收起指针': 'Hide local cursor while controlling',
};

/** 简体中文 → 繁體中文（香港）。 */
const ZH2HK: Record<string, string> = {
  // ── DeviceViewModel ──
  '视频应用投屏': '視頻應用投屏',
  'AirPlay / DLNA 视频': 'AirPlay / DLNA 視頻',
  '网络媒体投放': '網絡媒體投放',
  '正在投放视频': '正在投放視頻',
  '型号读取中': '型號讀取中',
  '本地网络': '本地網絡',
  'AirPlay 已连接': 'AirPlay 已連接',
  '未连接': '未連接',
  'USB 已连接，等待 Apple 通道': 'USB 已連接，等待 Apple 通道',
  '已连接': '已連接',
  '已配对，请解锁设备': '已配對，請解鎖設備',
  '已连接并配对': '已連接並配對',
  '设备连接异常': '設備連接異常',
  // ── About / Update / DeviceBinding / Startup / AppPrompt 等 ──
  '检测到当前视频画面持续为黑屏': '檢測到當前視頻畫面持續為黑屏',
  '画面恢复后自动关闭': '畫面恢復後自動關閉',
  '有音频': '有音頻',
  '无音频': '無音頻',
  '关闭': '關閉',
  '预览设备': '預覽設備',
  '继续': '繼續',
  '开发者提示预览': '開發者提示預覽',
  '检测到另一个 iPhoneMirror 程序正在运行。请选择要保留的窗口。': '檢測到另一個 iPhoneMirror 程式正在運行。請選擇要保留的視窗。',
  '关闭其他窗口': '關閉其他視窗',
  '关闭当前窗口': '關閉當前視窗',
  'iPhoneMirror 无法启动': 'iPhoneMirror 無法啟動',
  '诊断日志': '診斷日誌',
  '错误详情': '錯誤詳情',
  '打开日志位置': '打開日誌位置',
  '以真实设备档案管理 USB、AirPlay 和 Bluetooth 身份绑定。': '以真實設備檔案管理 USB、AirPlay 和 Bluetooth 身份綁定。',
  '查看完整 Release': '查看完整 Release',
  '当前版本': '當前版本',
  '最新版本': '最新版本',
  '发布时间': '發佈時間',
  '稍后提醒': '稍後提醒',
  '立即更新': '立即更新',
  '低延迟 iPhone 屏幕投射、录制、直播与虚拟摄像头。': '低延遲 iPhone 屏幕投射、錄製、直播與虛擬攝像頭。',
  '更新状态': '更新狀態',
  '可随时检查 GitHub Release 更新。': '可隨時檢查 GitHub Release 更新。',
  '检查更新': '檢查更新',
  '更新日志': '更新日誌',
  '许可证信息': '許可證資訊',
  '关于': '關於',
  '更新设置': '更新設定',
  '诊断': '診斷',
  '控制后台检查、自动下载、镜像加速和发布通道。': '控制後台檢查、自動下載、鏡像加速和發佈通道。',
  '启动时检查更新': '啟動時檢查更新',
  '发现更新后自动开始下载': '發現更新後自動開始下載',
  '自动选择最快更新下载线路': '自動選擇最快更新下載線路',
  '提醒正式版更新': '提醒正式版更新',
  '提醒 Beta 预览版更新': '提醒 Beta 預覽版更新',
  '日志位置': '日誌位置',
  '打开日志目录': '打開日誌目錄',
  '清理日志和更新缓存': '清理日誌和更新緩存',
  '实时日志  ·  Ctrl+L': '即時日誌  ·  Ctrl+L',
  '清空视图': '清空視圖',
  '日志视图已清空（不会删除磁盘日志）': '日誌視圖已清空（不會刪除磁盤日誌）',
  '正在等待蓝牙控制连接': '正在等待藍牙控制連接',
  '设备列表中通常显示为：{0}': '設備列表中通常顯示為：{0}',
  '等待 HID 鼠标连接': '等待 HID 滑鼠連接',
  'iPhone：若再次出现配对提示窗口，点击“配对”。': 'iPhone：若再次出現配對提示視窗，點擊「配對」。',
  '蓝牙控制无法启动': '藍牙控制無法啟動',
  '启动失败': '啟動失敗',
  '蓝牙控制需要刷新配对': '藍牙控制需要刷新配對',
  '需要重新配对': '需要重新配對',
  '我已重新配对': '我已重新配對',
  '蓝牙反向控制已开启（实验）': '藍牙反向控制已開啟（實驗）',
  '按 {0} 释放鼠标': '按 {0} 釋放滑鼠',
  '{0} 秒后自动关闭': '{0} 秒後自動關閉',
  '请确认准备工作后继续': '請確認準備工作後繼續',
  '启用无线控制前请确认': '啟用無線控制前請確認',
  '启用有线控制前请确认': '啟用有線控制前請確認',
  '投屏未能继续': '投屏未能繼續',
  '反控未能继续': '反控未能繼續',
  'USB 投屏配置未完成': 'USB 投屏配置未完成',
  '投屏已停止': '投屏已停止',
  '请检查设备和连接后重试': '請檢查設備和連接後重試',
  '请重新插拔数据线后重试': '請重新插拔數據線後重試',
  '重启设备后可再次投屏': '重啟設備後可再次投屏',
  '请重启 iPhone 或 iPad 后再试。': '請重啟 iPhone 或 iPad 後再試。',
  '请保持设备解锁，重新插拔数据线后再试。': '請保持設備解鎖，重新插拔數據線後再試。',
  '请停止投屏后重新开始；仍失败时重新连接设备。': '請停止投屏後重新開始；仍失敗時重新連接設備。',
  '只读预览': '唯讀預覽',
  '工作区页面': '工作區頁面',
  '快速切换主窗口中的所有工作区状态': '快速切換主視窗中的所有工作區狀態',
  '子窗口与弹窗': '子視窗與彈窗',
  '打开现有窗口的安全预览；网络、设备和破坏性操作已隔离': '打開現有視窗的安全預覽；網絡、設備和破壞性操作已隔離',
  '运行期参数': '運行期參數',
  '参数仅影响当前进程，便于检查主题、缩放和窗口协调': '參數僅影響當前進程，便於檢查主題、縮放和視窗協調',
  '窗口检查器': '視窗檢查器',
  '主窗口透明度': '主視窗透明度',
  '主窗口置顶': '主視窗置頂',
  '窗口预设': '視窗預設',
  '紧凑 1280×700': '緊湊 1280×700',
  '默认 1540×900': '預設 1540×900',
  '最大化': '最大化',
  '重置参数': '重置參數',
  '激活': '啟用',
  '预览窗口已打开': '預覽視窗已打開',
  '打开预览失败': '打開預覽失敗',
  '参数已恢复默认值': '參數已恢復預設值',
  '版本': '版本',
  '区域': '區域',
  '主题': '主題',
  '文字缩放': '文字縮放',
  '窗口数': '視窗數',
  '我的设备档案': '我的設備檔案',
  '添加 AirPlay 设备档案': '添加 AirPlay 設備檔案',
  '重命名档案': '重命名檔案',
  '删除档案': '刪除檔案',
  '选择设备档案': '選擇設備檔案',
  '为此档案选择并管理三种连接身份。': '為此檔案選擇並管理三種連接身份。',
  '有线 USB': '有線 USB',
  'AirPlay': 'AirPlay',
  'Bluetooth': 'Bluetooth',
  '绑定选择设备': '綁定選擇設備',
  '连接设备': '連接設備',
  '未绑定': '未綁定',
  '已绑定 · 已连接': '已綁定 · 已連接',
  '已绑定 · 当前镜像': '已綁定 · 當前鏡像',
  '已绑定 · 当前不可用': '已綁定 · 當前不可用',
  '已绑定 · 已断开': '已綁定 · 已斷開',
  '型号信息待获取': '型號資訊待獲取',
  '未命名设备': '未命名設備',
  '无法创建设备档案。': '無法創建設備檔案。',
  '输入设备档案名称': '輸入設備檔案名稱',
  '应用': '套用',
  '请先为该档案绑定 USB 或 AirPlay 设备。': '請先為該檔案綁定 USB 或 AirPlay 設備。',
  '无法启动 Bluetooth HID 连接。请确认电脑蓝牙已开启。': '無法啟動 Bluetooth HID 連接。請確認電腦藍牙已開啟。',
  '设备身份不能为空。': '設備身份不能為空。',
  '该设备身份已经绑定到设备档案。': '該設備身份已經綁定到設備檔案。',
  '该设备身份已绑定到另一台设备档案。': '該設備身份已綁定到另一台設備檔案。',
  '设备档案不存在。': '設備檔案不存在。',
  '检测到的设备型号不一致，无法绑定。': '檢測到的設備型號不一致，無法綁定。',
  '设备型号一致，需要用户确认。': '設備型號一致，需要用戶確認。',
  '无法自动验证设备型号，需要用户确认。': '無法自動驗證設備型號，需要用戶確認。',
  '无法保存 Bluetooth 设备绑定。': '無法保存 Bluetooth 設備綁定。',
  // ── AboutWindow ──
  '最新': '最新',
  '版本更新': '版本更新',
  '清理完成：删除 %d 个文件，释放 %s；%d 个正在使用或无权限的文件已跳过。': '清理完成：刪除 %d 個文件，釋放 %s；%d 個正在使用或無權限的文件已跳過。',
  '清理失败：%s': '清理失敗：%s',
  // ── BluetoothClientBinding ──
  '请选择与“{0}”对应的蓝牙手机': '請選擇與「{0}」對應的藍牙手機',
  '解除绑定': '解除綁定',
  '刷新蓝牙客户端': '刷新藍牙客戶端',
  '确认绑定': '確認綁定',
  '取消': '取消',
  '绑定蓝牙手机': '綁定藍牙手機',
  '已刷新：{0} 个蓝牙客户端': '已刷新：{0} 個藍牙客戶端',
  '已清除「{0}」的绑定标记（本移植未做持久化，重启后回到原状）': '已清除「{0}」的綁定標記（本移植未做持久化，重啟後回到原狀）',
  '该条目当前没有绑定标记可清除。': '該條目當前沒有綁定標記可清除。',
  // ── BluetoothConnection ──
  '等待 Bluetooth HID 连接': '等待 Bluetooth HID 連接',
  '本设备正在广播 Bluetooth HID 设备': '本設備正在廣播 Bluetooth HID 設備',
  '等待设备订阅 HID 服务': '等待設備訂閱 HID 服務',
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
  '投屏': '投屏',
  '投屏来源': '投屏來源',
  '设置': '設定',
  '设备绑定器': '設備綁定器',
  '界面语言': '界面語言',
  '应用主题': '應用主題',
  '应用模式': '應用模式',
  '开始投屏': '開始投屏',
  '停止投屏': '停止投屏',
  '刷新画面': '刷新畫面',
  '独立窗口': '獨立窗口',
  '调节画面': '調節畫面',
  '全屏预览': '全屏預覽',
  '录制与推流': '錄製與推流',
  '敬请期待': '敬請期待',

  // ── Index 导航 / 页脚 / 选择器（补充）──
  '投屏控制': '投屏控制',
  '选择投屏来源': '選擇投屏來源',
  '投屏设置': '投屏設定',
  '管理真实设备的 USB、AirPlay 和 Bluetooth 身份绑定': '管理真實設備的 USB、AirPlay 和 Bluetooth 身份綁定',
  '输出设置': '輸出設定',
  '驱动管理': '驅動管理',
  '关于与更新': '關於與更新',
  '输出': '輸出',
  '驱动': '驅動',
  '高级设置': '進階設定',
  '开发者工具': '開發者工具',
  '该功能': '該功能',
  '鸿蒙版尚未实现。': '鴻蒙版尚未實現。',
  '反控接管时收起指针': '反控接管時收起指標',
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
 */
export function set_language(index: number): void {
  AppStorage.setOrCreate<number>(LANG_INDEX_KEY, index);
  const tag: string = LANGUAGE_TAGS[index];
  if (tag && tag !== 'system') {
    try {
      // ★ 静态方法：i18n.System.setAppPreferredLanguage（@since 20），不是 context 上的方法。
      //   失败不影响运行时 t() 翻译（resources 里的串仍走各自 locale 文件），吞掉避免崩溃。
      i18n.System.setAppPreferredLanguage(tag);
    } catch (e) {
      // 系统层切换失败不影响运行时 t() 翻译；吞掉避免崩溃。
    }
  }
}
