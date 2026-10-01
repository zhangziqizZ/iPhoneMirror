#!/usr/bin/env python3
"""从 Fluent System Icons 的 SVG 生成 ArkTS 图标数据表（只生成上半部分）。

背景：
  上游界面是 WPF（WPF-UI 4.3.0），图标用 <ui:SymbolIcon Symbol="PhoneDesktop24"/>。
  SymbolIcon 背后是 Fluent System Icons（microsoft/fluentui-system-icons，MIT）。
  OHOS 没有这个字体，但每个图标都是一段纯矢量路径，可以原样搬成 ArkUI 的
  Shape + Path（坐标一个不改）。

本脚本只生成「图标数据表」这一上半部分：
  entry/src/main/ets/common/FluentIcon.ets 的 HAND_WRITTEN_START 分隔线之前的内容
  （文件头注释 + IconGlyph 类 + build_icon_table() + ICON_TABLE + icon_glyph() +
  收录图标清单注释）。

下半部分（FluentSymbol 组件）是**手写的、带密度换算的两步绘制**，生成器绝不覆盖：
  重新生成时，若输出文件已存在且含 HAND_WRITTEN_START 标记，则原样保留标记之后的
  手写组件；否则用 DEFAULT_COMPONENT（与手写组件保持一致的正确实现）兜底。

⚠ 为什么组件不能由生成器产出：早期生成器把整个文件（含组件）重写，曾几次把
  正确的「px_per_vp / fit_scale 两步绘制」覆盖回没有密度换算的朴素实现，导致
  「图标比原版小一圈、缩在方框左上角」反复回退。故改为「数据表自动生成、
  组件手写且保留」。

用法（在工程根目录执行）：
  python3 tools/gen_fluent_icons.py tools/fluent-icons \\
      entry/src/main/ets/common/FluentIcon.ets
"""
import glob
import os
import re
import sys


# 原版界面里的手绘轮廓图标（不是 SymbolIcon，而是 MainWindow.xaml 内联的 <Path>）。
# 这里同样原样搬，坐标一个不改。来源标注在下方每条的注释里。
EXTRA_ICONS = [
    # MainWindow.xaml:1270-1274  WaitingForDeviceState 的手机轮廓
    #   <Path Width="38" Height="48" Data="M13,2 L25,2 ... Z M15,7 L23,7"
    #         Stroke="{DynamicResource PreviewMutedTextBrush}" StrokeThickness="2"
    #         StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stretch="Uniform"/>
    ('DeviceOutline', 38, 48,
     'M13,2 L25,2 C31,2 35,6 35,12 L35,36 C35,42 31,46 25,46 L13,46 '
     'C7,46 3,42 3,36 L3,12 C3,6 7,2 13,2 Z M15,7 L23,7'),
]


# ── 手写组件区与自动生成区的分界标记 ───────────────────────────────────────
# 生成器只重写 START 之前的数据表；START 之后（到 END 之前）的手写组件原样保留。
HAND_WRITTEN_START = (
    "// ╔════════════════════════════════════════════════════════════════════════╗\n"
    "// ║ 以下为「手写组件区」（FluentSymbol）。                                  ║\n"
    "// ║ 本文件上半部分是 tools/gen_fluent_icons.py 自动生成的图标数据表；      ║\n"
    "// ║ 重新生成时只重写上半部分，本行之后的手写组件原样保留，绝不覆盖。       ║\n"
    "// ║ 若需修改图标画法，改这里即可，不要改上面的数据表。                     ║\n"
    "// ╚════════════════════════════════════════════════════════════════════════╝"
)
HAND_WRITTEN_END = (
    "// ╔════════════════════════════════════════════════════════════════════════╗\n"
    "// ║ 手写组件区结束。                                                      ║\n"
    "// ╚════════════════════════════════════════════════════════════════════════╝"
)


# 兜底：当输出文件不存在（全新生成）时使用。务必与手写组件保持一致 ——
# 即带密度换算的两步绘制（px_per_vp / fit_scale），否则图标会缩在方框左上角。
# 注意：正常流程下输出文件已存在且含分隔线，此兜底极少触发，但必须正确。
DEFAULT_COMPONENT = r'''/**
 * Fluent 图标组件 —— 对应原版的 <ui:SymbolIcon Symbol=... FontSize=.../>。
 *
 *   iconName          原版的 Symbol 名（如 PhoneDesktop24、Dismiss20）
 *   iconSize          原版的 FontSize（如 20、16、15、14、44）—— 单位 vp（= WPF 的 DIP）
 *   iconHeight        非正方形图标才需要（手机轮廓 38×48）；0 表示与 iconSize 相同
 *   iconColor         原版由 Foreground / Style 决定的颜色
 *   iconOutline       描边模式：原版 WaitingForDeviceState 里的手机轮廓是 Stroke
 *                     画法，不是 Fill；其余 SymbolIcon 都是填充画法。
 *   iconOutlineWidth  描边线宽（vp，对应原版 StrokeThickness）
 *
 * ⚠ 属性名必须以 `icon` 开头。自定义组件的继承链是
 *   CustomComponent → BaseCustomComponent → CommonAttribute → CommonMethod，
 *   而 CommonMethod 里已经有 `outline()` 与 `outlineWidth()` 两个属性方法。
 *   一旦 @Prop 取了同名就会撞上基类成员，报：
 *     TS2416: Property 'outline' in type 'FluentSymbol' is not assignable
 *             to the same property in base type 'CustomComponent'.
 *   CompileArkTS 会直接失败。故用 iconOutline / iconOutlineWidth 避开，
 *   与既有的 iconName / iconSize / iconColor 命名保持一致。
 */
@Component
export struct FluentSymbol {
  @Prop iconName: string = 'Info24';
  @Prop iconSize: number = 20;
  // 非正方形图标（手机轮廓 38x48）才需要单独指定高度；0 表示与 iconSize 相同。
  @Prop iconHeight: number = 0;
  @Prop iconColor: ResourceColor = '#FFF5F5F7';
  // 原版 WaitingForDeviceState 的手机轮廓是 Stroke 画法，不是 Fill。
  @Prop iconOutline: boolean = false;
  @Prop iconOutlineWidth: number = 2;

  /** UIContext 取不到也不能抛 —— build() 里抛异常没有人接手。 */
  private ui_context(): UIContext | null {
    try {
      return this.getUIContext();
    } catch (error) {
      return null;
    }
  }

  /** 布局框高度（vp）。 */
  private box_height(): number {
    return this.iconHeight > 0 ? this.iconHeight : this.iconSize;
  }

  /**
   * viewBox → 布局框 的等比放大倍数。
   *
   * 路径坐标单位是 px，布局框单位是 vp ⇒ 倍数 = 目标 px ÷ viewBox 单位数。
   * 宽高两个方向取小值，等价于 WPF 的 Stretch=Uniform。
   */
  private fit_scale(): number {
    const density: number = px_per_vp(this.ui_context());
    const by_width: number = this.iconSize * density / icon_glyph(this.iconName).vw;
    const by_height: number = this.box_height() * density / icon_glyph(this.iconName).vh;
    const smaller: number = by_width < by_height ? by_width : by_height;
    return smaller > 0 ? smaller : 1;
  }

  build() {
    // 根节点用带显式尺寸的 Stack：Shape 这类自绘组件的测量值可能为 0，
    // 直接把它当根会在部分父容器里塌成 0×0（见 Index.ets preview_waiting_device 的注释）。
    Stack({ alignContent: Alignment.Center }) {
      // ★ 这里**不再设置 viewPort**。
      //
      // ArkUI 的 Shape.viewPort 走 ShapeContainerPattern::ViewPortTransform：
      //   scale = min(contentSize / viewPort.ConvertToPx(), ...)      两者都折成 px
      //   tx/ty = 内容框中心 − (viewPort 尺寸/2 + 左上角) × scale       缩放中心是子节点左上角
      // 而 Path.commands 的坐标是 **px**、viewPort 的 width/height 是 **vp**（内部再转 px）
      // ⇒ 两套单位混在一起，系数恒差一个屏幕密度；又因为缩放中心在左上角，
      //    图标不会随方框放大并居中，而是缩在左上角。
      //
      // 实机取证（1920×1280 截图；密度由「按钮 height(38) 实测 44px」「图标底座
      // width(68) 实测 80px」两处独立反推，均为 1.175）：
      //   · PhoneDesktop24 / iconSize=44 → 墨迹 22px；「1 单位 = 1px」应为 20px，
      //     按「viewBox 铺满方框」应为 43px
      //   · DeviceOutline / 38×48 / 56×71 → 墨迹 34×44px；「1 单位 = 1px」应为 32×44px
      //   ⇒ 实测就是「viewBox 的 1 个单位恒等于 1px，且贴在方框左上角」。
      //
      // 改成两步，单位各自明确、不依赖 viewPort：
      //   ① Shape 的画布直接写成 viewBox 的 px 尺寸（px 字符串，单位无歧义）；
      //   ② 由根 Stack 把这块画布居中，再用 .scale() 等比放大到布局框。
      Shape() {
        Path()
          .commands(icon_glyph(this.iconName).path)
          .width(icon_glyph(this.iconName).vw + 'px')
          .height(icon_glyph(this.iconName).vh + 'px')
          .fill(this.iconOutline ? Color.Transparent : this.iconColor)
          .stroke(this.iconOutline ? this.iconColor : Color.Transparent)
          // 描边和 commands 同处 px 空间，会被 .scale() 一起放大 ⇒
          // 先除掉放大倍数，最终落在屏幕上的线宽才等于 iconOutlineWidth（vp）。
          .strokeWidth(this.iconOutline ? this.iconOutlineWidth / this.fit_scale() : 0)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
      .width(icon_glyph(this.iconName).vw + 'px')
      .height(icon_glyph(this.iconName).vh + 'px')
      .scale({ x: this.fit_scale(), y: this.fit_scale() })
    }
    .width(this.iconSize)
    .height(this.box_height())
  }
}'''


def parse_svg(path):
    """返回 (view_w, view_h, path_d)。"""
    text = open(path, encoding='utf-8').read()
    vb = re.search(r'viewBox="([^"]+)"', text)
    if vb is None:
        raise ValueError(f'{path}: 没有 viewBox')
    parts = vb.group(1).replace(',', ' ').split()
    vw, vh = float(parts[2]), float(parts[3])
    d = re.search(r'<path[^>]*\sd="([^"]+)"', text)
    if d is None:
        raise ValueError(f'{path}: 没有 path d')
    return vw, vh, ' '.join(d.group(1).split())


def fmt(value):
    """24.0 -> 24；16.5 -> 16.5。"""
    return str(int(value)) if float(value).is_integer() else str(value)


def build_prefix(icons):
    """生成「自动生成区」全部内容（文件头 + 数据表 + icon_glyph + 清单注释）。"""
    lines = []
    lines.append('// FluentIcon.ets —— Fluent System Icons 的矢量路径表（自动生成，勿手改上半部分）')
    lines.append('//')
    lines.append('// 生成器：tools/gen_fluent_icons.py（路径表／本文件上半部分）／tools/gen_font_ink.py（字体墨迹核对）')
    lines.append('// 数据源：microsoft/fluentui-system-icons（MIT License）')
    lines.append('//         assets/<图标名>/SVG/ic_fluent_<名>_<尺寸>_regular.svg')
    lines.append('//')
    lines.append('// 为什么这样做：')
    lines.append('//   上游界面（WPF + WPF-UI 4.3.0）用 <ui:SymbolIcon Symbol="PhoneDesktop24"/>，')
    lines.append('//   它渲染的是 Fluent System Icons 字体的对应码点。鸿蒙没有这个字体，但每个图标')
    lines.append('//   本身是一段纯矢量路径 —— 这里原样搬过来自绘，坐标一个不改。')
    lines.append('//')
    lines.append('// ★ 字体口径核对结论（实测 FluentSystemIcons-Regular.ttf）：')
    lines.append('//   字体 unitsPerEm=500、hhea ascent=500 descent=0，且每个字形的点坐标与同名 SVG')
    lines.append('//   完全同构：缩放比正好 500/viewBox，y 轴翻转。⇒ 字体的 em 框就是 SVG 的 viewBox，')
    lines.append('//   路径坐标可直接映射，不需按墨迹重新居中。')
    lines.append('//')
    lines.append('// ★ 绘制口径（关键，防回退）：')
    lines.append('//   路径坐标单位是 px，而布局尺寸单位是 vp。早期实现用 Shape.viewPort 把两者混在')
    lines.append('//   一起，导致「图标比原版小一圈、缩在方框左上角」。FluentSymbol 改用两步绘制')
    lines.append('//   （见下方手写组件 px_per_vp / fit_scale）：先把画布写成 viewBox 的 px 尺寸，')
    lines.append('//   再由根 Stack 居中并 .scale() 放大到布局框。本文件下半部分（FluentSymbol 组件）')
    lines.append('//   是手写的、生成器保留，切勿在生成器里覆盖它。')
    lines.append('//')
    lines.append('// 用法：FluentSymbol({ iconName: \'PhoneDesktop24\', iconSize: 20, iconColor: ACCENT })')
    lines.append('')
    lines.append("import { UIContext, display } from '@kit.ArkUI';")
    lines.append('')
    lines.append('/** 一个图标的绘制数据：视口尺寸（= 原 SVG 的 viewBox）与路径指令（= path d）。 */')
    lines.append('export class IconGlyph {')
    lines.append('  readonly vw: number;')
    lines.append('  readonly vh: number;')
    lines.append('  readonly path: string;')
    lines.append('')
    lines.append('  constructor(vw: number, vh: number, path: string) {')
    lines.append('    this.vw = vw;')
    lines.append('    this.vh = vh;')
    lines.append('    this.path = path;')
    lines.append('  }')
    lines.append('}')
    lines.append('')
    lines.append('// 空图标：名字写错时画不出来，而不是抛异常把界面搞崩。')
    lines.append("const EMPTY_GLYPH: IconGlyph = new IconGlyph(20, 20, '');")
    lines.append('')
    lines.append('function build_icon_table(): Map<string, IconGlyph> {')
    lines.append('  const table: Map<string, IconGlyph> = new Map<string, IconGlyph>();')
    for name, vw, vh, d in icons:
        lines.append(f"  table.set('{name}',")
        lines.append(f'    new IconGlyph({fmt(vw)}, {fmt(vh)},')
        # 路径很长，按 96 字符折行只为可读；JS 字符串拼接会保持原值
        chunks = [d[i:i + 96] for i in range(0, len(d), 96)]
        for idx, chunk in enumerate(chunks):
            suffix = '' if idx == len(chunks) - 1 else ' +'
            lines.append(f"      '{chunk}'{suffix}")
        lines.append('    ));')
    lines.append('  return table;')
    lines.append('}')
    lines.append('')
    lines.append('const ICON_TABLE: Map<string, IconGlyph> = build_icon_table();')
    lines.append('')
    lines.append('/** 按名字取图标；名字不存在时返回空图标（不抛异常）。 */')
    lines.append('export function icon_glyph(name: string): IconGlyph {')
    lines.append('  const found: IconGlyph | undefined = ICON_TABLE.get(name);')
    lines.append('  return found !== undefined ? found : EMPTY_GLYPH;')
    lines.append('}')
    lines.append('')
    lines.append('// 本表收录的图标（与原版 SymbolIcon 的 Symbol 名一一对应）：')
    lines.append('// ' + '、'.join(n for n, _, _, _ in icons))
    lines.append('')
    lines.append('/**')
    lines.append(' * 1 vp 等于多少 px。')
    lines.append(' *')
    lines.append(' * 为什么必须有它：`Path.commands` 的坐标单位是 **px**（官方文档「Default unit: px」），')
    lines.append(' * 而 `.width()` 等布局尺寸的单位是 **vp**。两者混用会恒差一个屏幕密度，这正是')
    lines.append(' * 「图标比原版小一圈、还缩在方框左上角」的根因（见 FluentSymbol.build 的注释）。')
    lines.append(' *')
    lines.append(' * 取 UIContext.vp2px：它与渲染管线里 `Dimension::ConvertToPx()` 用的是同一份密度')
    lines.append(' * （见 arkui_ace_engine 的 ShapeContainerPattern::ViewPortTransform），所以换算精确。')
    lines.append(' * 拿不到时依次退回 display 的密度、1 —— 宁可尺寸不准，也绝不让绘制抛异常。')
    lines.append(' */')
    lines.append('function px_per_vp(ui: UIContext | null): number {')
    lines.append('  if (ui !== null) {')
    lines.append('    try {')
    lines.append('      const from_ui: number = ui.vp2px(1);')
    lines.append('      if (from_ui > 0) {')
    lines.append('        return from_ui;')
    lines.append('      }')
    lines.append('    } catch (error) {')
    lines.append('      // 落到下面的 display 兜底')
    lines.append('    }')
    lines.append('  }')
    lines.append('  try {')
    lines.append('    const from_display: number = display.getDefaultDisplaySync().densityPixels;')
    lines.append('    if (from_display > 0) {')
    lines.append('      return from_display;')
    lines.append('    }')
    lines.append('  } catch (error) {')
    lines.append('    // 落到 1')
    lines.append('  }')
    lines.append('  return 1;')
    lines.append('}')
    lines.append('')
    return '\n'.join(lines)


def load_handwritten(out_path):
    """读取已有输出文件里的手写组件；没有则返回 None（调用方用 DEFAULT_COMPONENT）。"""
    if not os.path.exists(out_path):
        return None
    cur = open(out_path, encoding='utf-8').read()
    if HAND_WRITTEN_START in cur:
        suffix = cur.split(HAND_WRITTEN_START, 1)[1]
        if HAND_WRITTEN_END in suffix:
            suffix = suffix.split(HAND_WRITTEN_END, 1)[0]
        return suffix.strip('\n')
    # 兼容：旧文件没有分隔线 —— 只抢救 FluentSymbol 组件本身，绝不能把上面的数据表也卷进来。
    # 锚定到组件文档注释（唯一含「Fluent 图标组件」的那段），再取其前的 /** 作为起点，
    # 到结构体收尾的 \n}（顶格）为止。
    si = cur.find('Fluent 图标组件')
    if si == -1:
        return None
    doc_start = cur.rfind('/**', 0, si)
    struct_idx = cur.find('export struct FluentSymbol', doc_start)
    if struct_idx == -1:
        return None
    end_idx = cur.find('\n}', struct_idx) + len('\n}')
    return cur[doc_start:end_idx].strip('\n')


def main():
    src_dir = sys.argv[1]
    out_path = sys.argv[2]

    icons = []
    for svg in sorted(glob.glob(os.path.join(src_dir, '*.svg'))):
        name = os.path.splitext(os.path.basename(svg))[0]
        vw, vh, d = parse_svg(svg)
        icons.append((name, vw, vh, d))

    # 手绘轮廓（手机等待态）排在最前；其余按名字排序。
    icons = EXTRA_ICONS + icons

    prefix = build_prefix(icons)
    handwritten = load_handwritten(out_path)
    if handwritten is None:
        handwritten = DEFAULT_COMPONENT

    out = (
        prefix.rstrip('\n')
        + '\n\n'
        + HAND_WRITTEN_START
        + '\n\n'
        + handwritten
        + '\n\n'
        + HAND_WRITTEN_END
        + '\n'
    )

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as fh:
        fh.write(out)

    print(f'生成 {out_path}')
    print(f'图标数：{len(icons)}（数据表 {len(icons)} 项 + 手写组件区）')
    for name, vw, vh, d in icons:
        print(f'  {name:<24} viewBox {fmt(vw)}x{fmt(vh)}  path {len(d)} 字符')


if __name__ == '__main__':
    main()
