"""查证 lcms2 对渲染意图的区分能力，用于界定「哪些意图无法用现有材料验证」。

背景与结论：

ICC 定义四种渲染意图。但本库能取得的 profile 是：
- `srgb.icc`、`display.icc`：matrix/TRC 型，白点接近 D65；
- `cmyk_printer.icc`：LUT 型，白点约 (0.862, 0.893, 0.743)（SWOP 印刷白）。

实测（本脚本）：对这两组 profile 对，lcms2 在**四种意图**下给出**逐位相同**
的结果，且 `flags = 0` 与 `NOOPTIMIZE` 两种设置下都一样。

因此本库对 matrix/TRC 型 profile 固定使用媒体相对比色，是**与参考实现一致的
行为**，而不是省略——因为对这类 profile，四种意图在参考实现上也不可区分。

「绝对比色」需要参考实现能真正区分意图才能建立判据。当前材料下做不到，
故本库不实现它，并在 README 的「明确不做」中注明原因。

**踩过的坑**：本脚本的第一版把随机采样写在意图循环内部，于是不同意图拿到的
是**不同的输入**，比较结果毫无意义（还误报出 255 级的巨大差异）。
比较必须固定输入——这是写对照实验的基本要求。
"""

import sys

sys.stdout.reconfigure(encoding="utf-8")
import numpy as np
from PIL import Image, ImageCms

PAIRS = [
    ("sRGB -> 显示器", "testdata/srgb.icc", "testdata/display.icc", "RGB", "RGB"),
    ("sRGB -> CMYK", "testdata/srgb.icc", "testdata/cmyk_printer.icc", "RGB", "CMYK"),
]

INTENTS = [
    (0, "感知"),
    (1, "相对比色"),
    (2, "饱和度"),
    (3, "绝对比色"),
]

FLAG_SETS = [
    ("默认(0)", 0),
    ("NOOPTIMIZE", int(ImageCms.Flags.NOOPTIMIZE)),
]

# 固定输入：采样只做一次，所有意图/flag 组合都用同一批样本
rng = np.random.default_rng(31)
SAMPLES = [tuple(int(v) for v in s) for s in rng.integers(0, 256, size=(64, 3))]

all_same = True
for label, sp, dp, ms, md in PAIRS:
    src = ImageCms.getOpenProfile(sp)
    dst = ImageCms.getOpenProfile(dp)
    print(f"=== {label}（{len(SAMPLES)} 个固定彩色样本）===")
    for flags_name, flags in FLAG_SETS:
        results = {}
        for ival, iname in INTENTS:
            x = ImageCms.buildTransformFromOpenProfiles(
                src, dst, ms, md, renderingIntent=ival, flags=flags
            )
            im = Image.new("RGB", (8, 8))
            im.putdata(SAMPLES)
            results[iname] = list(ImageCms.applyTransform(im, x).get_flattened_data())
        base = results["相对比色"]
        line = []
        for _, iname in INTENTS:
            d = max(
                max(abs(a[k] - b[k]) for k in range(len(a)))
                for a, b in zip(base, results[iname])
            )
            line.append(f"{iname}:与相对的最大差 {d}")
            if d != 0:
                all_same = False
        print(f"  flags={flags_name:12s} " + " | ".join(line))
    print()

print("结论：", end="")
if all_same:
    print("四种意图在所有 flags 设置下结果**完全相同**。")
    print("      即 lcms2 对这组 profile 不区分意图，因此「绝对比色」")
    print("      无法用当前材料建立判据。")
else:
    print("存在可区分的意图，可用于建立判据。")
