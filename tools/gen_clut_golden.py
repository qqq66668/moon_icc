"""生成 CLUT 变换的金标数据。

两类金标：

1. **网格节点**（`clut_node_golden`）：期望值就是 CLUT 在该节点上的**存储值**
   （由独立 Python 解析后按 v2 Lab 编码换算）。

   关键细节：**该 profile 的输入表不是恒等**。实测通道 0 在 v=0.75 处表值为
   49151，而恒等应为 49344。因此"设备值取 节点索引/(gc-1) 就会落在节点上"
   这个假设**不成立**——直接这样取会落在节点 5 与 6 之间的 0.9765 处。

   所以本脚本**反解输入表**，求出使表输出恰为 `j/(gc-1)` 的设备值，再以这些
   设备值作为测试输入。这样结果才精确落在节点上，节点判据的锋利性才成立。

   为什么节点判据重要：节点值不依赖插值算法的任何细节。任何正确实现在节点上
   都必须返回存储值。因此它能单独钉住**解析、索引步长、Lab 解码**三件事。

2. **lcms2 端到端样本**（`lcms2_lab_golden`）：随机 CMYK 值经 lcms2
   （intent=1，对应 A2B1）变换得到的 Lab，用于验证插值路径。
   lcms2 经 Pillow 只能给 8 位 Lab，故按 8 位量化比较。
"""

import sys, struct

sys.stdout.reconfigure(encoding="utf-8")
import numpy as np
from PIL import Image, ImageCms

PROFILE = "testdata/cmyk_printer.icc"
OUT = "clut_golden_wbtest.mbt"
N_RANDOM = 300
SEED = 7
NODE_STRIDE = 2

d = open(PROFILE, "rb").read()
n = struct.unpack(">I", d[128:132])[0]
tags = {}
for i in range(n):
    o = 132 + i * 12
    sig = d[o : o + 4].decode()
    off, sz = struct.unpack(">II", d[o + 4 : o + 12])
    tags[sig] = (off, sz)


def parse_lut16(off, sz):
    raw = d[off : off + sz]
    ic, oc, gc = raw[8], raw[9], raw[10]
    in_e, out_e = struct.unpack(">HH", raw[48:52])
    tables = []
    for ch in range(ic):
        b = 52 + ch * in_e * 2
        tables.append(struct.unpack(f">{in_e}H", raw[b : b + in_e * 2]))
    clut_start = 52 + ic * in_e * 2
    clut = struct.unpack(
        f">{(gc**ic) * oc}H", raw[clut_start : clut_start + (gc**ic) * oc * 2]
    )
    return ic, oc, gc, in_e, out_e, clut, tables


off, sz = tags["A2B1"]
ic, oc, gc, in_e, out_e, clut, in_tables = parse_lut16(off, sz)
print(f"A2B1: ic={ic} oc={oc} gc={gc} in_entries={in_e} out_entries={out_e}")

max_dev = max(abs(in_tables[0][j] - j * 65535 / (in_e - 1)) for j in range(in_e))
print(f"输入表相对恒等的最大偏差 = {max_dev:.0f}（非恒等，故需反解）")

V2 = 65280.0
SPAN = gc - 1


def invert_input_table(ch, target):
    """求设备值 v，使通道 ch 的输入表插值输出恰为 target（0..1）。"""
    vals = in_tables[ch]
    t = target * 65535.0
    if t <= vals[0]:
        return 0.0
    if t >= vals[-1]:
        return 1.0
    i = 1
    while i < in_e and vals[i] < t:
        i += 1
    lo, hi = vals[i - 1], vals[i]
    if hi == lo:
        return i / (in_e - 1)
    return ((i - 1) + (t - lo) / (hi - lo)) / (in_e - 1)


def node_lab(index):
    base = index * oc
    return (
        clut[base + 0] / V2 * 100.0,
        clut[base + 1] / V2 * 255.0 - 128.0,
        clut[base + 2] / V2 * 255.0 - 128.0,
    )


node_idx = list(range(0, gc, NODE_STRIDE))
node_rows = []
for j0 in node_idx:
    for j1 in node_idx:
        for j2 in node_idx:
            for j3 in node_idx:
                idx = ((j0 * gc + j1) * gc + j2) * gc + j3
                L, A, B = node_lab(idx)
                inp = [
                    invert_input_table(0, j0 / SPAN),
                    invert_input_table(1, j1 / SPAN),
                    invert_input_table(2, j2 / SPAN),
                    invert_input_table(3, j3 / SPAN),
                ]
                node_rows.append((inp[0], inp[1], inp[2], inp[3], L, A, B))
print(f"网格节点金标: {len(node_rows)} 条（步长 {NODE_STRIDE}）")

rng = np.random.default_rng(SEED)
samples = rng.integers(0, 256, size=(N_RANDOM, 4))
lab_prof = ImageCms.createProfile("LAB")
# 与 link 金标一致，取 lcms2 的精确路径（NOOPTIMIZE）而非默认的 CLUT 近似
xform = ImageCms.buildTransformFromOpenProfiles(
    ImageCms.getOpenProfile(PROFILE),
    lab_prof,
    "CMYK",
    "LAB",
    renderingIntent=1,
    flags=int(ImageCms.Flags.NOOPTIMIZE),
)
lcms_rows = []
for s in samples:
    px = tuple(int(v) for v in s)
    Lp, ap, bp = ImageCms.applyTransform(Image.new("CMYK", (1, 1), px), xform).getpixel(
        (0, 0)
    )
    lcms_rows.append((px[0], px[1], px[2], px[3], Lp, ap, bp))
print(f"lcms2 样本金标: {len(lcms_rows)} 条")

HEADER = f'''///|
/// CLUT 变换的金标数据。
///
/// **本文件由 `tools/gen_clut_golden.py` 自动生成，请勿手工编辑。**
///
/// 参考来源：
/// - 网格节点：按 ICC 规范从 `testdata/cmyk_printer.icc` 的 `A2B1` tag
///   独立解析 u16，按 **v2 Lab 编码**（上限 0xFF00）换算。
/// - 随机样本：lcms2（经 Pillow 的 ImageCms，intent=1）。
///
/// ## 为什么节点用例的输入值不是 `索引/{SPAN}`
///
/// 该 profile 的**输入表不是恒等**（实测通道 0 在 v=0.75 处表值 49151，
/// 恒等应为 49344）。因此直接取 `j/{SPAN}` 作设备值并不会落在 CLUT 节点上，
/// 而是落在节点之间——这样节点判据就不成立了。
///
/// 生成脚本因此**反解输入表**，求出使表输出恰为 `j/{SPAN}` 的设备值，
/// 再以这些值作为测试输入。于是结果精确落在节点上，期望值即存储值。

///|
/// 一个网格节点金标：四个通道的设备值 + 期望 Lab。
pub struct ClutNodeCase {{
  v0 : Double
  v1 : Double
  v2 : Double
  v3 : Double
  l : Double
  a : Double
  b : Double
}}

///|
/// 一个 lcms2 样本金标：(CMYK 0..255, 期望的 8 位 Lab)。
///
/// Pillow 的 LAB 模式约定：L 通道 0..255 映射 0..100，
/// a/b 通道 0..255 映射 -128..127。
pub struct Lcms2LabCase {{
  c : Int
  m : Int
  y : Int
  k : Int
  lp : Int
  ap : Int
  bp : Int
}}

///|
/// {len(node_rows)} 个网格节点（每轴索引 {node_idx}）。
pub let clut_node_golden : Array[ClutNodeCase] = [
'''

lines = [HEADER]
for (v0, v1, v2, v3, L, A, B) in node_rows:
    lines.append(
        f"  {{ v0: {v0!r}, v1: {v1!r}, v2: {v2!r}, v3: {v3!r}, "
        f"l: {L:.6f}, a: {A:.6f}, b: {B:.6f} }},\n"
    )
lines.append("]\n\n")
lines.append(
    f"///|\n/// lcms2（intent=1）给出的 {len(lcms_rows)} 个随机 CMYK 样本。\n"
    "pub let lcms2_lab_golden : Array[Lcms2LabCase] = [\n"
)
for (c, m, y, k, lp, ap, bp) in lcms_rows:
    lines.append(
        f"  {{ c: {c}, m: {m}, y: {y}, k: {k}, "
        f"lp: {lp}, ap: {ap}, bp: {bp} }},\n"
    )
lines.append("]\n")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("".join(lines))
print(f"已生成 {OUT}")
