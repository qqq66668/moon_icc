"""生成跨类型链接的金标数据（sRGB ↔ CMYK 打印机）。

背景：`ColorTransform` 现在两侧各自可以是 matrix/TRC 型或 LUT 型，
中间统一用 PCS XYZ 衔接。本脚本用 lcms2 生成两个方向的参考结果：

- `srgb_to_cmyk_golden`：matrix/TRC 源 → LUT 目标
- `cmyk_to_srgb_golden`：LUT 源 → matrix/TRC 目标

样本用**随机 RGB / CMYK**，而不是灰阶——灰阶只覆盖一个切片，
无法暴露通道间的耦合错误（本项目在矩阵求逆上就栽过这个跟头）。

参考实现：lcms2（经 Pillow ImageCms），`flags = NOOPTIMIZE`
（与其它金标一致，取精确路径而非默认的 CLUT 近似），intent = 1。
"""

import sys

sys.stdout.reconfigure(encoding="utf-8")
import numpy as np
from PIL import Image, ImageCms

OUT = "cross_link_golden_wbtest.mbt"
N = 300
SEED = 23

srgb = ImageCms.getOpenProfile("testdata/srgb.icc")
cmyk = ImageCms.getOpenProfile("testdata/cmyk_printer.icc")
noopt = int(ImageCms.Flags.NOOPTIMIZE)

print(f"目标 profile: {ImageCms.getProfileDescription(cmyk)}")

rng = np.random.default_rng(SEED)

# ---- 方向 1：sRGB -> CMYK ----
rgb_samples = rng.integers(0, 256, size=(N, 3))
x1 = ImageCms.buildTransformFromOpenProfiles(
    srgb, cmyk, "RGB", "CMYK", renderingIntent=1, flags=noopt
)
im = Image.new("RGB", (20, 15))
im.putdata([tuple(int(v) for v in s) for s in rgb_samples])
cmyk_out = list(ImageCms.applyTransform(im, x1).get_flattened_data())
print(f"sRGB -> CMYK: {len(cmyk_out)} 个样本")

# ---- 方向 2：CMYK -> sRGB ----
cmyk_samples = rng.integers(0, 256, size=(N, 4))
x2 = ImageCms.buildTransformFromOpenProfiles(
    cmyk, srgb, "CMYK", "RGB", renderingIntent=1, flags=noopt
)
im2 = Image.new("CMYK", (20, 15))
im2.putdata([tuple(int(v) for v in s) for s in cmyk_samples])
rgb_out = list(ImageCms.applyTransform(im2, x2).get_flattened_data())
print(f"CMYK -> sRGB: {len(rgb_out)} 个样本")

HEADER = f'''///|
/// 跨类型链接的金标数据。
///
/// **本文件由 `tools/gen_cross_link_golden.py` 自动生成，请勿手工编辑。**
///
/// 参考实现：lcms2（经 Pillow ImageCms），`flags = NOOPTIMIZE`，intent = 1。
/// 用到的 profile：`testdata/srgb.icc`（matrix/TRC 型）与
/// `testdata/cmyk_printer.icc`（LUT 型，mft2）。
///
/// 样本是**随机** RGB / CMYK，不是灰阶——灰阶只覆盖色彩空间的一个切片，
/// 无法暴露通道间的耦合错误。

///|
/// sRGB → CMYK 的一个样本：(输入 8 位 RGB, 期望 8 位 CMYK)。
pub struct SrgbToCmykCase {{
  r : Int
  g : Int
  b : Int
  c : Int
  m : Int
  y : Int
  k : Int
}}

///|
/// CMYK → sRGB 的一个样本：(输入 8 位 CMYK, 期望 8 位 RGB)。
pub struct CmykToSrgbCase {{
  c : Int
  m : Int
  y : Int
  k : Int
  r : Int
  g : Int
  b : Int
}}

///|
/// {N} 个随机 RGB 样本经 lcms2 变换到 CMYK。
pub let srgb_to_cmyk_golden : Array[SrgbToCmykCase] = [
'''

lines = [HEADER]
for s, o in zip(rgb_samples, cmyk_out):
    lines.append(
        f"  {{ r: {int(s[0])}, g: {int(s[1])}, b: {int(s[2])}, "
        f"c: {o[0]}, m: {o[1]}, y: {o[2]}, k: {o[3]} }},\n"
    )
lines.append("]\n\n")
lines.append(
    f"///|\n/// {N} 个随机 CMYK 样本经 lcms2 变换到 sRGB。\n"
    "pub let cmyk_to_srgb_golden : Array[CmykToSrgbCase] = [\n"
)
for s, o in zip(cmyk_samples, rgb_out):
    lines.append(
        f"  {{ c: {int(s[0])}, m: {int(s[1])}, y: {int(s[2])}, k: {int(s[3])}, "
        f"r: {o[0]}, g: {o[1]}, b: {o[2]} }},\n"
    )
lines.append("]\n")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("".join(lines))
print(f"已生成 {OUT}")
