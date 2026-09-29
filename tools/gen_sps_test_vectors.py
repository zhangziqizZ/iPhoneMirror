#!/usr/bin/env python3
"""按 H.264 spec 7.3.2.1.1 精确构造 SPS 测试向量（供 test_sps_parse.cpp 使用）。

生成 → RBSP → emulation prevention 转义 → 包上起始码和 NAL 头 → 打印 hex。
同时自检：转义是否真的发生过（否则测试没有覆盖到 unescape 路径）。
"""


class BitWriter:
    def __init__(self):
        self.bits = []

    def u(self, n, v):
        for i in range(n - 1, -1, -1):
            self.bits.append((v >> i) & 1)

    def ue(self, v):
        m = v + 1
        nbits = m.bit_length()
        self.u(nbits - 1, 0)
        self.u(nbits, m)

    def se(self, v):
        k = 2 * v - 1 if v > 0 else -2 * v
        self.ue(k)

    def trailing(self):
        self.u(1, 1)
        while len(self.bits) % 8:
            self.bits.append(0)

    def to_bytes(self):
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            b = 0
            for bit in self.bits[i:i + 8]:
                b = (b << 1) | bit
            out.append(b)
        return bytes(out)


def escape(rbsp: bytes) -> bytes:
    """emulation prevention：连续两个 0x00 后的下个字节 <=3 时插 0x03。"""
    out = bytearray()
    zeros = 0
    for b in rbsp:
        if zeros >= 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


def build_sps(profile, constraints, level, w_mbs, h_map, crop, constraints_bits=None):
    w = BitWriter()
    w.u(8, profile)
    w.u(8, 0xC0 if constraints_bits is None else constraints_bits)
    w.u(8, level)
    w.ue(0)            # seq_parameter_set_id
    w.ue(4)            # log2_max_frame_num_minus4
    w.ue(0)            # pic_order_cnt_type = 0
    w.ue(4)            # log2_max_pic_order_cnt_lsb_minus4
    w.ue(2)            # max_num_ref_frames
    w.u(1, 0)          # gaps_in_frame_num_value_allowed_flag
    w.ue(w_mbs)        # pic_width_in_mbs_minus1
    w.ue(h_map)        # pic_height_in_map_units_minus1
    w.u(1, 1)          # frame_mbs_only_flag
    w.u(1, 1)          # direct_8x8_inference_flag
    if crop is None:
        w.u(1, 0)      # frame_cropping_flag = 0
    else:
        w.u(1, 1)      # frame_cropping_flag = 1
        for v in crop:  # left, right, top, bottom
            w.ue(v)
    w.u(1, 0)          # vui_parameters_present_flag
    w.trailing()
    return bytes([0x67]) + w.to_bytes()  # NAL 头：type=7, nal_ref_idc=3


def annexb(nalu: bytes) -> bytes:
    return b"\x00\x00\x00\x01" + escape(nalu)


def show(name, sps_rbsp):
    escaped = annexb(sps_rbsp)
    print(f"{name}:")
    print(f"  raw len={len(sps_rbsp)} escaped len={len(escaped)} "
          f"(+{len(escaped) - len(sps_rbsp)} 转义字节)")
    assert len(escaped) > len(sps_rbsp), "转义没发生，向量不覆盖 unescape 路径！"
    print("  hex = " + escaped.hex())


# 向量 A：1920×1088 编码，crop right=2/bottom=2（4:2:0 → 右 4px、下 4px），
# 显示 1916×1084。pic_w_mbs=119 的 ue 编码有 6 个前导 0，必产生 00 00 03。
show("A: 1080p crop->1916x1084", build_sps(66, 0xC0, 40, 119, 67, (0, 2, 0, 2)))

# 向量 B：896×1920 竖屏无 crop（iPhone 竖屏 mirroring 常见编码尺寸）。
show("B: 896x1920 portrait", build_sps(66, 0xC0, 30, 55, 119, None))
