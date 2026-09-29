#!/usr/bin/env python3
"""从 FluentSystemIcons-Regular.ttf 取出每个图标的**字形墨迹**，写成 fluent-font-ink.json。

为什么需要它：
  上游 WPF 用 <ui:SymbolIcon Symbol="X" FontSize="N"/>，渲染的是 **字体字形**：
  字形按 FontSize/unitsPerEm 缩放，所以"图标到底多大"由字体决定，而不是由
  SVG 的 viewBox 决定（viewBox 里含设计留白，两者差 20%~50%）。
  鸿蒙没有这个字体，我们用 Shape+Path 复刻，就必须把字形尺寸也搬过来。

字形名与符号名的对应：Symbol="PhoneDesktop24" → 字形 "ic_fluent_phone_desktop_24_regular"。

用法：
  python3 tools/gen_font_ink.py FluentSystemIcons-Regular.ttf > tools/fluent-font-ink.json

字体来源（MIT）：microsoft/fluentui-system-icons → fonts/FluentSystemIcons-Regular.ttf
"""
import json
import re
import struct
import sys

SVG_DIR_DEFAULT = 'tools/fluent-icons'


def camel_to_snake(base):
    return re.sub(r'(?<!^)(?=[A-Z])', '_', base).lower()


def symbol_to_glyph(symbol):
    """PhoneDesktop24 → ic_fluent_phone_desktop_24_regular（可能生成多个候选）。"""
    m = re.match(r'^([A-Za-z0-9]*?[A-Za-z])(\d+)$', symbol)
    if m is None:
        return []
    base, size = m.group(1), m.group(2)
    cands = [f'ic_fluent_{camel_to_snake(base)}_{size}_regular']
    # Speaker220 / MusicNote220 这类：名字里本身带数字
    m2 = re.match(r'^(.*?)(\d)$', base)
    if m2 is not None:
        cands.append(f'ic_fluent_{camel_to_snake(m2.group(1))}_{m2.group(2)}_{size}_regular')
    return cands


class Ttf:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        n = self.u16(4)
        self.tables = {}
        for i in range(n):
            off = 12 + 16 * i
            tag = self.d[off:off + 4].decode('latin1')
            self.tables[tag] = (self.u32(off + 8), self.u32(off + 12))
        head = self.tables['head'][0]
        self.units_per_em = self.u16(head + 18)
        self.index_to_loc = self.s16(head + 50)
        self.num_glyphs = self.u16(self.tables['maxp'][0] + 4)
        self.loca = self.tables['loca'][0]
        self.glyf = self.tables['glyf'][0]
        self.hmtx = self.tables['hmtx'][0]
        self.names = self._glyph_names()

    def u16(self, o):
        return struct.unpack('>H', self.d[o:o + 2])[0]

    def s16(self, o):
        return struct.unpack('>h', self.d[o:o + 2])[0]

    def u32(self, o):
        return struct.unpack('>I', self.d[o:o + 4])[0]

    def _glyph_names(self):
        post = self.tables['post'][0]
        version = self.u32(post)
        if version != 0x00020000:
            raise ValueError(f'post 表不是 2.0 版（{version:#x}），取不到字形名')
        n = self.u16(post + 32)
        idx = [self.u16(post + 34 + 2 * i) for i in range(n)]
        pool = post + 34 + 2 * n
        custom, p = [], pool
        end = self.tables['post'][0] + self.tables['post'][1]
        while p < end:
            ln = self.d[p]
            custom.append(self.d[p + 1:p + 1 + ln].decode('latin1'))
            p += 1 + ln
        names = {}
        for gid, i in enumerate(idx):
            if i >= 258:
                names.setdefault(custom[i - 258], gid)
        return names

    def bbox(self, gid, depth=0):
        """返回 (xMin, yMin, xMax, yMax)，单位=字体单位；空字形返回 None。"""
        if depth > 6 or gid >= self.num_glyphs:
            return None
        if self.index_to_loc == 0:
            start = self.u16(self.loca + 2 * gid) * 2
            end = self.u16(self.loca + 2 * gid + 2) * 2
        else:
            start = self.u32(self.loca + 4 * gid)
            end = self.u32(self.loca + 4 * gid + 4)
        if start == end:
            return None
        o = self.glyf + start
        if self.s16(o) >= 0:                      # 简单字形：表头就是包围盒
            return (self.s16(o + 2), self.s16(o + 4), self.s16(o + 6), self.s16(o + 8))
        p = o + 10                                # 复合字形：并集所有组件
        res = None
        while True:
            flags, gi = self.u16(p), self.u16(p + 2)
            p += 4 + (4 if flags & 1 else 2)
            if flags & 8:
                p += 2
            elif flags & 0x40:
                p += 4
            elif flags & 0x80:
                p += 8
            cb = self.bbox(gi, depth + 1)
            if cb is not None:
                res = cb if res is None else (min(res[0], cb[0]), min(res[1], cb[1]),
                                              max(res[2], cb[2]), max(res[3], cb[3]))
            if not flags & 0x20:
                break
        return res

    def advance(self, gid):
        return self.u16(self.hmtx + 4 * gid)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    ttf_path = sys.argv[1]
    svg_dir = sys.argv[2] if len(sys.argv) > 2 else SVG_DIR_DEFAULT
    import glob
    import os

    font = Ttf(ttf_path)
    out = {
        '_comment': '由 tools/gen_font_ink.py 从 FluentSystemIcons-Regular.ttf 生成，勿手改',
        '_unitsPerEm': font.units_per_em,
        '_meaning': 'ink: 字形墨迹包围盒（字体单位，xMin/yMin/xMax/yMax）',
        'glyphs': {},
    }
    miss = []
    for svg in sorted(glob.glob(os.path.join(svg_dir, '*.svg'))):
        symbol = os.path.splitext(os.path.basename(svg))[0]
        hit = None
        for cand in symbol_to_glyph(symbol):
            if cand in font.names:
                hit = cand
                break
        if hit is None:
            miss.append(symbol)
            continue
        gid = font.names[hit]
        bb = font.bbox(gid)
        out['glyphs'][symbol] = {
            'glyph': hit,
            'ink': list(bb) if bb else None,
            'advance': font.advance(gid),
        }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
    print('', file=sys.stdout)
    if miss:
        print(f'⚠ 字体里没找到 {len(miss)} 个字形：{", ".join(miss)}', file=sys.stderr)


if __name__ == '__main__':
    main()
