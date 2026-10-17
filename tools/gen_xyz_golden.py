# -*- coding: utf-8 -*-
"""生成合成 XYZ-PCS profile（`testdata/xyz_lut.icc`）的测试金标。

参考实现：lcms2（经 Pillow 的 ImageCms）。两张表：

- `xyz_a2b_golden`：`RGB -> LAB`（设备 → PCS，PCS 为 XYZ 的 profile）；
- `xyz_rgb2rgb_golden`：`RGB -> RGB` 组合变换（内部先 A2B0 再 B2A0）。

另外做**前提检查**：该 profile 的两条管线都是线性斜坡（只有恒等曲线与
线性 CLUT），因此解析期望值是精确的：

    A2B0：XYZ = 设备值 × D50
    B2A0：设备值 = XYZ / (65535/32768) = XYZ / 1.99997…
    组合：设备输出 = 设备输入 × D50 / 1.99997…

若把 XYZ 的 PCS 编码误当成满量程 `0xFFFF`（u1Fixed16），期望式会整体差 2 倍。
脚本会把实测与解析期望的偏差打出来，作为前提是否成立的可见事实。

输出：`xyz_lut_golden_wbtest.mbt`（自动生成，勿手工编辑）。
"""
import os
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8")
from PIL import Image, ImageCms

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ICC = os.path.join(ROOT, "testdata", "xyz_lut.icc")
OUT = os.path.join(ROOT, "xyz_lut_golden_wbtest.mbt")

NOOPTIMIZE = 0x0100
NOCACHE = 0x0040
XYZ_SCALE = 65535.0 / 32768.0  # ≈ 1.99997
D50 = (0.9642, 1.0, 0.8249)

FIXED = [
    (0, 0, 0), (255, 255, 255), (128, 128, 128), (64, 64, 64), (192, 192, 192),
    (1, 1, 1), (254, 254, 254), (255, 0, 0), (0, 255, 0), (0, 0, 255),
    (64, 192, 32), (17, 34, 51), (200, 100, 50), (10, 200, 50),
]


def lcg(n, seed=777):
    out = []
    x = seed
    for _ in range(n):
        x = (1103515245 * x + 12345) % (2 ** 31)
        out.append(x % 256)
    return out


vals = lcg(3 * 12)
RANDOM = [(vals[i * 3], vals[i * 3 + 1], vals[i * 3 + 2]) for i in range(12)]
SAMPLES = FIXED + RANDOM


def run_fwd(samples):
    """RGB -> LAB（A2B 方向）。

    必须带 NOOPTIMIZE：lcms2 默认会把管线重采样成近似 CLUT，
    实测在 `RGB(150,23,4)` 处 b 通道差 4 级（带 NOOPTIMIZE 时与解析值完全一致）。
    """
    prof = ImageCms.getOpenProfile(ICC)
    lab = ImageCms.createProfile("LAB", 5000.0)
    tr = ImageCms.buildTransform(
        prof, lab, "RGB", "LAB", renderingIntent=0, flags=NOOPTIMIZE | NOCACHE
    )
    im = Image.new("RGB", (len(samples), 1))
    im.putdata(samples)
    out = ImageCms.applyTransform(im, tr)
    return [tuple(out.getdata())[i] for i in range(len(samples))]


def run_rt(samples):
    prof = ImageCms.getOpenProfile(ICC)
    tr = ImageCms.buildTransform(
        prof, prof, "RGB", "RGB", renderingIntent=0, flags=NOOPTIMIZE | NOCACHE
    )
    im = Image.new("RGB", (len(samples), 1))
    im.putdata(samples)
    out = ImageCms.applyTransform(im, tr)
    return [tuple(out.getdata())[i] for i in range(len(samples))]


fwd = run_fwd(SAMPLES)
rt = run_rt(SAMPLES)

# 前提检查：组合变换必须等于 device×D50/1.99997…（线性斜坡的解析期望）
worst_rt = 0
for rgb, got in zip(SAMPLES, rt):
    want = tuple(
        int(round(rgb[c] / 255.0 * D50[c] / XYZ_SCALE * 255.0)) for c in range(3)
    )
    worst_rt = max(worst_rt, max(abs(a - b) for a, b in zip(got, want)))
print(f"组合变换与解析期望 v×D50/1.99997 的最大偏差：{worst_rt} 级")
if worst_rt > 1:
    raise SystemExit(
        "组合变换与 u1Fixed15 的解析期望不符——XYZ PCS 编码假设可能需要复核"
    )

# 前提检查 2：A2B 方向必须真的产生了 XYZ（而不是恒等复制），
# 否则"解码成 XYZ 再转 Lab"这条路径没有被有效覆盖。
spread = max(max(x) - min(x) for x in fwd)
print(f"RGB->LAB 输出的通道跨度（判据有效性检查）：{spread}")
if spread < 50:
    raise SystemExit("A2B 输出跨度过小，判据可能无效")


def emit(name, cases, doc, struct_name, fields):
    lines = ["", "///|", f"/// {doc}", f"pub let {name} : Array[{struct_name}] = ["]
    for inp, exp in cases:
        lines.append("  {")
        lines.append(f"    r: {inp[0]}, g: {inp[1]}, b: {inp[2]},")
        lines.append("    " + ", ".join(f"{f}: {v}" for f, v in zip(fields, exp)) + ",")
        lines.append("  },")
    lines.append("]")
    return lines


header = [
    "///|",
    "/// 合成 XYZ-PCS profile（`testdata/xyz_lut.icc`）的测试金标。",
    "///",
    "/// **本文件由 `tools/gen_xyz_golden.py` 自动生成，请勿手工编辑。**",
    "///",
    "/// 参考实现：lcms2（经 Pillow 的 `ImageCms`）。该 profile 由",
    "/// `tools/gen_xyz_lut_profile.py` 合成：PCS 为 `XYZ `，`A2B0`/`B2A0`",
    "/// 都是恒等曲线 + 2×2×2 线性 CLUT，节点值分别取 `(i,j,k)×32768`",
    "/// 与 `(i,j,k)×65535`。因此解析期望值是精确的：",
    "/// 设备→XYZ 为恒等、XYZ→设备为 `XYZ/1.99997…`。",
    "///",
    "/// 结构体复用 `v4lut_golden_wbtest.mbt` 中的 `V4A2BCase` / `V4B2ACase`。",
]

lines = header
lines += emit(
    "xyz_a2b_golden",
    list(zip(SAMPLES, fwd)),
    "设备 → PCS 金标：设备 RGB（0..255）+ 期望的 8 位 Lab。",
    "V4A2BCase",
    ["lp", "ap", "bp"],
)
lines += emit(
    "xyz_rgb2rgb_golden",
    list(zip(SAMPLES, rt)),
    "端到端金标：设备 RGB 经 PCS 再回到设备 RGB（8 位）。",
    "V4B2ACase",
    ["out_r", "out_g", "out_b"],
)

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines) + "\n")
print(f"已写出 {OUT}：{len(lines)} 行，每张表 {len(SAMPLES)} 个样本")
