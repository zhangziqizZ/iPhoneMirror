#!/usr/bin/env python3
"""从 Fluent System Icons 的 SVG 生成 ArkTS 图标表。

背景：
  上游界面是 WPF（WPF-UI 4.3.0），图标用 <ui:SymbolIcon Symbol="PhoneDesktop24"/>。
  SymbolIcon 背后是 Fluent System Icons（microsoft/fluentui-system-icons，MIT）。
  OHOS 没有这个字体，但每个图标都是一段纯矢量路径，可以原样搬成 ArkUI 的
  Shape + Path（Shape.viewPort 对应 SVG 的 viewBox）。

本脚本把 assets/<Name>/SVG/ic_fluent_<name>_<size>_regular.svg 的
viewBox 与 <path d="..."> 抽出来，生成 entry/src/main/ets/common/FluentIcon.ets。
不改一个坐标 —— 与原版字体图标逐点一致。

用法（在工程根目录执行）：
  python3 tools/gen_fluent_icons.py tools/fluent-icons \\
      entry/src/main/ets/common/FluentIcon.ets

SVG 源已随工程放在 tools/fluent-icons/（MIT，见 THIRD_PARTY_NOTICES.md），
所以重新生成不需要联网。若要补充新图标，从
  https://cdn.jsdelivr.net/gh/microsoft/fluentui-system-icons@main/assets/<目录名>/SVG/
取对应的 ic_fluent_*.svg 放进该目录，再把 Symbol 名加进下面 EXTRA_ICONS
之外的清单即可（Fluent 图标会自动全部收录）。
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


def main():
    src_dir = sys.argv[1]
    out_path = sys.argv[2]

    icons = []
    for svg in sorted(glob.glob(os.path.join(src_dir, '*.svg'))):
        name = os.path.splitext(os.path.basename(svg))[0]
        vw, vh, d = parse_svg(svg)
        icons.append((name, vw, vh, d))

    # 手绘轮廓（手机等待态）排在最前，方便在表里一眼看到它不是 Fluent 的；
    # 其余按名字排序，与 Symbol 名对应关系一目了然。
    icons = EXTRA_ICONS + icons

    lines = []
    lines.append('// FluentIcon.ets —— Fluent System Icons 的矢量路径表（自动生成，勿手改）')
    lines.append('//')
    lines.append('// 生成器：tools/gen_fluent_icons.py')
    lines.append('// 数据源：microsoft/fluentui-system-icons（MIT License）')
    lines.append('//         assets/<图标名>/SVG/ic_fluent_<名>_<尺寸>_regular.svg')
    lines.append('//')
    lines.append('// 为什么这样做：')
    lines.append('//   上游界面（WPF + WPF-UI 4.3.0）用 <ui:SymbolIcon Symbol="PhoneDesktop24"/>，')
    lines.append('//   它渲染的是 Fluent System Icons 字体里的对应码点。鸿蒙没有这个字体，')
    lines.append('//   但每个图标本身是一段纯矢量路径 —— 这里原样搬过来，用 ArkUI 的')
    lines.append('//   Shape.viewPort（等价于 SVG 的 viewBox）+ Path.commands 绘制，')
    lines.append('//   坐标一个不改，因此与原版字体图标逐点一致。')
    lines.append('//')
    lines.append('// 用法：FluentSymbol({ iconName: \'PhoneDesktop24\', iconSize: 20, iconColor: ACCENT })')
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
    lines.append(' * Fluent 图标组件 —— 对应原版的 <ui:SymbolIcon Symbol=... FontSize=.../>。')
    lines.append(' *')
    lines.append(' *   iconName          原版的 Symbol 名（如 PhoneDesktop24、Dismiss20）')
    lines.append(' *   iconSize          原版的 FontSize（如 20、16、15、14、38、34、32）')
    lines.append(' *   iconColor         原版由 Foreground / Style 决定的颜色')
    lines.append(' *   iconOutline       描边模式：原版 WaitingForDeviceState 里的手机轮廓是 Stroke')
    lines.append(' *                     画法，不是 Fill；其余 SymbolIcon 都是填充画法。')
    lines.append(' *   iconOutlineWidth  描边线宽')
    lines.append(' *')
    lines.append(' * ⚠ 属性名必须以 `icon` 开头。自定义组件的继承链是')
    lines.append(' *   CustomComponent → BaseCustomComponent → CommonAttribute → CommonMethod，')
    lines.append(' *   而 CommonMethod 里已经有 `outline()` 与 `outlineWidth()` 两个属性方法。')
    lines.append(' *   一旦 @Prop 取了同名就会撞上基类成员，报：')
    lines.append(" *     TS2416: Property 'outline' in type 'FluentSymbol' is not assignable")
    lines.append(" *             to the same property in base type 'CustomComponent'.")
    lines.append(' *   CompileArkTS 会直接失败。故用 iconOutline / iconOutlineWidth 避开，')
    lines.append(' *   与既有的 iconName / iconSize / iconColor 命名保持一致。')
    lines.append(' */')
    lines.append('@Component')
    lines.append('export struct FluentSymbol {')
    lines.append("  @Prop iconName: string = 'Info24';")
    lines.append('  @Prop iconSize: number = 20;')
    lines.append('  // 非正方形图标（手机轮廓 38x48）才需要单独指定高度；0 表示与 iconSize 相同。')
    lines.append('  @Prop iconHeight: number = 0;')
    lines.append("  @Prop iconColor: ResourceColor = '#FFF5F5F7';")
    lines.append('  // 原版 WaitingForDeviceState 的手机轮廓是 Stroke 画法，不是 Fill。')
    lines.append('  @Prop iconOutline: boolean = false;')
    lines.append('  @Prop iconOutlineWidth: number = 2;')
    lines.append('')
    lines.append('  build() {')
    lines.append('    Shape() {')
    lines.append('      Path()')
    lines.append('        .commands(icon_glyph(this.iconName).path)')
    lines.append('        // 路径画布取 viewPort 的逻辑尺寸（= 原 SVG 的 viewBox）。')
    lines.append('        // Shape 负责把 viewPort 映射到组件实际尺寸，等价于 SVG 的 viewBox 缩放，')
    lines.append('        // 因此 iconSize 改变时图标等比缩放，与 WPF 的 Stretch 行为一致。')
    lines.append('        .width(icon_glyph(this.iconName).vw)')
    lines.append('        .height(icon_glyph(this.iconName).vh)')
    lines.append('        .fill(this.iconOutline ? Color.Transparent : this.iconColor)')
    lines.append('        .stroke(this.iconOutline ? this.iconColor : Color.Transparent)')
    lines.append('        .strokeWidth(this.iconOutline ? this.iconOutlineWidth : 0)')
    lines.append('        .strokeLineCap(LineCapStyle.Round)')
    lines.append('        .strokeLineJoin(LineJoinStyle.Round)')
    lines.append('    }')
    lines.append('    .viewPort({')
    lines.append('      x: 0,')
    lines.append('      y: 0,')
    lines.append('      width: icon_glyph(this.iconName).vw,')
    lines.append('      height: icon_glyph(this.iconName).vh,')
    lines.append('    })')
    lines.append('    .width(this.iconSize)')
    lines.append('    .height(this.iconHeight > 0 ? this.iconHeight : this.iconSize)')
    lines.append('  }')
    lines.append('}')
    lines.append('')

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(lines))

    print(f'生成 {out_path}')
    print(f'图标数：{len(icons)}')
    for name, vw, vh, d in icons:
        print(f'  {name:<24} viewBox {fmt(vw)}x{fmt(vh)}  path {len(d)} 字符')


if __name__ == '__main__':
    main()
