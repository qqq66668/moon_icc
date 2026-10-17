# -*- coding: utf-8 -*-
"""生成 v4 LUT（mAB / mBA）测试的金标数据。

参考实现：lcms2（经 Pillow 的 ImageCms）。

两个方向的取法不同，原因是 **8 位 Lab 输入格式器会给坐标加偏移**（实测见
`_research/lcms_probe/probe_coord.py`：用"恒等 CLUT + 恒等 A 曲线"的探针
profile 反解出 lcms2 送进 CLUT 的坐标，在近黑处比 `L8/255` 大 8/255），
所以 PCS → 设备方向不能用 `LAB` 模式输入去对拍，而应当用
**设备 → PCS → 设备** 的组合变换（`RGB` 进 `RGB` 出）：

- A2B（设备 → PCS）：`RGB -> LAB`，intent 0/1；
- B2A（PCS → 设备）：`RGB -> RGB`（内部 A2B 后再 B2A），intent 0/1，
  并加 `cmsFLAGS_NOOPTIMIZE`，避免 lcms2 把管线重采样成近似 CLUT。

输出：`v4lut_golden_wbtest.mbt`（自动生成，勿手工编辑）。
"""
import os
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8")
from PIL import Image, ImageCms

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ICC = os.path.join(ROOT, "testdata", "test4.icc")
OUT = os.path.join(ROOT, "v4lut_golden_wbtest.mbt")

NOOPTIMIZE = 0x0100
NOCACHE = 0x0040

# 固定样本集：端点、原色、灰阶 + 伪随机填充（固定种子，保证可复现）
FIXED = [
    (0, 0, 0), (255, 255, 255), (128, 128, 128), (1, 1, 1), (2, 2, 2),
    (5, 5, 5), (16, 16, 16), (64, 64, 64), (192, 192, 192), (254, 254, 254),
    (255, 0, 0), (0, 255, 0), (0, 0, 255),
    (255, 255, 0), (255, 0, 255), (0, 255, 255),
    (10, 200, 50), (200, 10, 200), (33, 66, 99), (86, 222, 190),
    (6, 245, 140), (120, 18, 158), (250, 250, 250), (17, 34, 51),
]

def lcg(n, seed=12345):
    """线性同余生成器：不依赖 Python 的随机实现细节，保证跨版本可复现。"""
    out = []
    x = seed
    for _ in range(n):
        x = (1103515245 * x + 12345) % (2 ** 31)
        out.append(x % 256)
    return out

vals = lcg(3 * 16)
RANDOM = [(vals[i * 3], vals[i * 3 + 1], vals[i * 3 + 2]) for i in range(16)]
SAMPLES = FIXED + RANDOM


def run_fwd(intent, samples):
    """RGB -> LAB（A2B 方向）。"""
    prof = ImageCms.getOpenProfile(ICC)
    lab = ImageCms.createProfile("LAB", 5000.0)
    tr = ImageCms.buildTransform(prof, lab, "RGB", "LAB",
                                 renderingIntent=intent, flags=0)
    im = Image.new("RGB", (len(samples), 1))
    im.putdata(samples)
    out = ImageCms.applyTransform(im, tr)
    return [tuple(out.getdata())[i] for i in range(len(samples))]


def run_rt(intent, samples):
    """RGB -> RGB（A2B 后再 B2A，不受 8 位 Lab 输入格式器影响）。"""
    prof = ImageCms.getOpenProfile(ICC)
    tr = ImageCms.buildTransform(prof, prof, "RGB", "RGB",
                                 renderingIntent=intent,
                                 flags=NOOPTIMIZE | NOCACHE)
    im = Image.new("RGB", (len(samples), 1))
    im.putdata(samples)
    out = ImageCms.applyTransform(im, tr)
    return [tuple(out.getdata())[i] for i in range(len(samples))]


a2b0 = run_fwd(0, SAMPLES)
a2b1 = run_fwd(1, SAMPLES)
b2a0 = run_rt(0, SAMPLES)
b2a1 = run_rt(1, SAMPLES)

# 前提检查：这些判据必须有区分度，否则对拍没有意义
d_a2b = sum(1 for x, y in zip(a2b0, a2b1) if x != y)
d_b2a = sum(1 for x, y in zip(b2a0, b2a1) if x != y)
print(f"intent 0 与 1 的差异样本数：A2B {d_a2b}/{len(SAMPLES)}，B2A {d_b2a}/{len(SAMPLES)}")
if d_a2b == 0 or d_b2a == 0:
    raise SystemExit("两个意图的输出完全相同，判据无区分度，请检查 tag 选取")

lines = []
w = lines.append
w("///|")
w("/// v4 LUT（`mAB ` / `mBA `）测试的金标数据。")
w("///")
w("/// **本文件由 `tools/gen_v4lut_golden.py` 自动生成，请勿手工编辑。**")
w("///")
w("/// 参考实现：lcms2（经 Pillow 的 `ImageCms`），样本 profile 为")
w("/// `testdata/test4.icc`（ICC v4.2，四个 LUT tag 均为 v4 类型）。")
w("///")
w("/// - A2B 方向：`RGB -> LAB`，8 位；")
w("/// - B2A 方向：`RGB -> RGB` 组合变换（内部先 A2B 再 B2A），8 位。")
w("///")
w("/// B2A 之所以不直接以 `LAB` 模式输入，是因为 lcms2 的 8 位 Lab 输入格式器")
w("/// 会给送进 CLUT 的坐标加一个偏移（近黑处约 8/255，用恒等探针 profile 实测），")
w("/// 直接对拍会把该偏移记成本库的误差。")
w("///")
w("/// Pillow 的 LAB 模式约定：L 通道 0..255 映射 0..100，a/b 通道 0..255 映射 -128..127。")
w("")
w("///|")
w("/// A2B 金标：设备 RGB（0..255）+ 期望的 8 位 Lab。")
w("pub struct V4A2BCase {")
w("  r : Int32")
w("  g : Int32")
w("  b : Int32")
w("  lp : Int32")
w("  ap : Int32")
w("  bp : Int32")
w("}")
w("")
w("///|")
w("/// B2A 金标：设备 RGB（0..255）经 PCS 后再回到设备 RGB（0..255）。")
w("pub struct V4B2ACase {")
w("  r : Int32")
w("  g : Int32")
w("  b : Int32")
w("  out_r : Int32")
w("  out_g : Int32")
w("  out_b : Int32")
w("}")


def emit(name, cases, doc):
    w("")
    w("///|")
    w(f"/// {doc}")
    w(f"pub let {name} : Array[V4A2BCase] = [")
    for (inp, exp) in cases:
        w("  {")
        w(f"    r: {inp[0]}, g: {inp[1]}, b: {inp[2]},")
        w(f"    lp: {exp[0]}, ap: {exp[1]}, bp: {exp[2]},")
        w("  },")
    w("]")


def emit_rt(name, cases, doc):
    w("")
    w("///|")
    w(f"/// {doc}")
    w(f"pub let {name} : Array[V4B2ACase] = [")
    for (inp, exp) in cases:
        w("  {")
        w(f"    r: {inp[0]}, g: {inp[1]}, b: {inp[2]},")
        w(f"    out_r: {exp[0]}, out_g: {exp[1]}, out_b: {exp[2]},")
        w("  },")
    w("]")


emit("v4_a2b0_golden", list(zip(SAMPLES, a2b0)),
     "感知意图（intent 0）的 A2B 金标，对应 tag `A2B0`。")
emit("v4_a2b1_golden", list(zip(SAMPLES, a2b1)),
     "媒体相对比色（intent 1）的 A2B 金标，对应 tag `A2B1`。")
emit_rt("v4_b2a0_golden", list(zip(SAMPLES, b2a0)),
        "感知意图（intent 0）的 B2A 金标，`A2B0` 与 `B2A0` 的组合变换。")
emit_rt("v4_b2a1_golden", list(zip(SAMPLES, b2a1)),
        "媒体相对比色（intent 1）的 B2A 金标，`A2B1` 与 `B2A1` 的组合变换。")

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines) + "\n")
print(f"已写出 {OUT}：{len(lines)} 行，每张表 {len(SAMPLES)} 个样本")
