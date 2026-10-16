"""生成四种渲染意图的金标数据（sRGB → CMYK 打印机）。

为什么用这一组 profile：本机只有它**能区分意图**——它含 `A2B0/A2B1/A2B2`
三张不同的 LUT。实测以媒体相对比色为基准，感知差 42 级、饱和度差 255 级、
绝对差 18 级。sRGB → 显示器 那组四种意图逐位相同，无法用于建立判据
（见 `tools/lcms2_intent_check.py`）。

参考实现：lcms2（经 Pillow ImageCms），`flags = NOOPTIMIZE`，200 个随机 RGB 样本。
"""

import sys

sys.stdout.reconfigure(encoding="utf-8")
import numpy as np
from PIL import Image, ImageCms

OUT = "intent_golden_wbtest.mbt"
N = 200
SEED = 41

src = ImageCms.getOpenProfile("testdata/srgb.icc")
dst = ImageCms.getOpenProfile("testdata/cmyk_printer.icc")
noopt = int(ImageCms.Flags.NOOPTIMIZE)

rng = np.random.default_rng(SEED)
samples = rng.integers(0, 256, size=(N, 3))
im = Image.new("RGB", (20, 10))
im.putdata([tuple(int(v) for v in s) for s in samples])

INTENTS = [(0, "perceptual"), (1, "relative"), (2, "saturation"), (3, "absolute")]

results = {}
for ival, iname in INTENTS:
    x = ImageCms.buildTransformFromOpenProfiles(
        src, dst, "RGB", "CMYK", renderingIntent=ival, flags=noopt
    )
    results[iname] = list(ImageCms.applyTransform(im, x).get_flattened_data())
    print(f"{iname:12s}: 已生成 {len(results[iname])} 个样本")

# 与相对比色的差异（说明意图确实可区分）
base = results["relative"]
for _, iname in INTENTS:
    d = max(
        max(abs(a[k] - b[k]) for k in range(4))
        for a, b in zip(base, results[iname])
    )
    print(f"  {iname:12s} 与相对比色的最大差: {d}")

HEADER = f'''///|
/// 四种渲染意图的金标数据（sRGB → CMYK 打印机）。
///
/// **本文件由 `tools/gen_intent_golden.py` 自动生成，请勿手工编辑。**
///
/// 参考实现：lcms2（经 Pillow ImageCms），`flags = NOOPTIMIZE`，
/// {N} 个随机 RGB 样本。
///
/// 为什么只有这一组 profile 能做意图判据：本机的 sRGB 与显示器 profile 都是
/// matrix/TRC 型，只有一组矩阵与曲线，lcms2 对它们四种意图给出逐位相同的结果；
/// 而 CMYK 打印机 profile 含 `A2B0/A2B1/A2B2` 三张不同的 LUT，意图确实可区分。

///|
/// 全部 {N} 个样本的输入 RGB（四个意图共用同一批输入，便于对比）。
pub let intent_inputs : Array[(Int, Int, Int)] = [
'''

lines = [HEADER]
for s in samples:
    lines.append(f"  ({int(s[0])}, {int(s[1])}, {int(s[2])}),\n")
lines.append("]\n\n")

for _, iname in INTENTS:
    lines.append(
        f"///|\n/// 意图 {iname} 的期望输出。\n"
        f"pub let intent_{iname} : Array[(Int, Int, Int, Int)] = [\n"
    )
    for o in results[iname]:
        lines.append(f"  ({o[0]}, {o[1]}, {o[2]}, {o[3]}),\n")
    lines.append("]\n\n")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("".join(lines))
print(f"已生成 {OUT}")
