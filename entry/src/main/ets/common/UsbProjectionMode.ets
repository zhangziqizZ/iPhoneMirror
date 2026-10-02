import { t } from './i18n';
// UsbProjectionMode.ets —— USB 投屏模式选项
//
// 数据源（逐条对应，一个不改）：
//   src/App/Models/DeviceCaptureState.cs : enum UsbProjectionMode : uint
//       Demo = 0, AirPlay = 1, Aisi = 2
//   src/App/ViewModels/MainViewModel.cs  : UsbProjectionModes 列表（第 281–289 行）
//       new(UsbProjectionMode.Demo,    "UsbModeDemoLabel",    "UsbModeDemoAdvantage",
//           "UsbModeDemoDisadvantage", "UsbModeDemoNotice"),
//       new(UsbProjectionMode.AirPlay, "UsbModeAirPlayLabel", "UsbModeAirPlayAdvantage",
//           "UsbModeAirPlayDisadvantage", "UsbModeAirPlayNotice"),
//       new(UsbProjectionMode.Aisi,    "UsbModeAisiLabel",    "UsbModeAisiAdvantage",
//           "UsbModeAisiDisadvantage", "UsbModeAisiNotice"),
//
//   UsbProjectionModeOption 是一个「延迟取文案」的类：
//       public string Label => LocalizationService.Get(labelResourceKey);
//   移植后单语言，于是按 Strings.zh-CN.xaml 的取值直接内联（每个常量后标原键名）。
//
// 用法：UsbProjectionModeInfoWindow 收一个 UsbProjectionModeOption，把它的四段文案
//       填进模式标题 / 优点 / 缺点 / 注意事项。

/** src/App/Models/DeviceCaptureState.cs: enum UsbProjectionMode : uint */
export enum UsbProjectionMode {
  Demo = 0,
  AirPlay = 1,
  Aisi = 2,
}

/** 一个模式的全部说明文案（对应 UsbProjectionModeOption 的四个属性）。 */
export class UsbProjectionModeOption {
  readonly mode: UsbProjectionMode;
  readonly label: string;
  readonly advantage: string;
  readonly disadvantage: string;
  readonly notice: string;

  constructor(mode: UsbProjectionMode, label: string,
              advantage: string, disadvantage: string, notice: string) {
    this.mode = mode;
    this.label = label;
    this.advantage = advantage;
    this.disadvantage = disadvantage;
    this.notice = notice;
  }
}

/** MainViewModel.UsbProjectionModes —— 顺序与文案一字不改。 */
export const USB_PROJECTION_MODES: UsbProjectionModeOption[] = [
  new UsbProjectionModeOption(
    UsbProjectionMode.Demo,
    'A 演示模式(推荐)',                                            // UsbModeDemoLabel
    '发送 Valeria=true 和设备原生 DisplaySize，由 iOS 输出完整的手机镜像，并保持固定演示状态。'
      + '兼容性和画面完整性最高，推荐日常使用。',                     // UsbModeDemoAdvantage
    'iOS 会进入 Apple 演示状态，状态栏日期、时间和电量会锁定为演示值，不能反映手机当前状态。',
                                                                    // UsbModeDemoDisadvantage
    '此模式不会启用视频 App 的 AirPlay 或外接播放画面。'),           // UsbModeDemoNotice
  new UsbProjectionModeOption(
    UsbProjectionMode.AirPlay,
    'B AirPlay(实验)',                                             // UsbModeAirPlayLabel
    '发送 Valeria=false，使用设备原生尺寸，并保留当前的首帧探测、横竖屏识别和自适应重配。'
      + '视频 App 可以切换到 AirPlay 或外接播放。',                  // UsbModeAirPlayAdvantage
    '外接内容的分辨率无法保证与手机和窗口完美自适应，可能出现裁切、比例异常或画面显示不全。',
                                                                    // UsbModeAirPlayDisadvantage
    '需要自定义时，连续点击右下角版本号 5 次开启高级模式。自定义 HPD1 尺寸存在风险，'
      + '错误参数可能导致黑屏、裁切或 USB 重连失败。'),               // UsbModeAirPlayNotice
  new UsbProjectionModeOption(
    UsbProjectionMode.Aisi,
    'C 爱思模式',                                                  // UsbModeAisiLabel
    '采用爱思同类方案，发送 Valeria=false 并固定请求 1565×1565，减少不同设备之间的分辨率协商差异。',
                                                                    // UsbModeAisiAdvantage
    '方形目标会限制源画面的清晰度，不适合画质优先；横屏内容还可能出现缩放、黑边或比例不理想。',
                                                                    // UsbModeAisiDisadvantage
    '此模式不会使用本项目的原生分辨率探测和横竖屏自适应重配。'),      // UsbModeAisiNotice
];

/** 按模式取选项；找不到时返回 Demo（原版列表里 Demo 一定在）。 */
export function usb_projection_mode_option(mode: UsbProjectionMode): UsbProjectionModeOption {
  for (let i = 0; i < USB_PROJECTION_MODES.length; i++) {
    if (USB_PROJECTION_MODES[i].mode === mode) {
      return USB_PROJECTION_MODES[i];
    }
  }
  return USB_PROJECTION_MODES[0];
}
