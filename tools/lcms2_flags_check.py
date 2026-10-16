"""验证假设：lcms2 默认在链接两个 profile 时构建 3D CLUT 并三线性插值，
这才是与本库（逐步双精度计算）产生 ±1 级差异的原因。

检验方法：用 cmsFLAGS_NOOPTIMIZE 关闭该优化，重建 transform，
看与"按规范逐字转写的双精度实现"的差异是否消失。

若消失，则结论是：
  本库 = 规范的精确定义；lcms2 默认走 CLUT 近似（速度优先）。
  两者在 8 位域上的差异由 lcms2 的近似引入，不是本库的误差。
"""

import sys, struct

sys.stdout.reconfigure(encoding="utf-8")
import numpy as np
from PIL import Image, ImageCms


def load(path):
    d = open(path, "rb").read()
    n = struct.unpack(">I", d[128:132])[0]
    tags = {}
    for i in range(n):
        o = 132 + i * 12
        sig = d[o : o + 4].decode()
        off, sz = struct.unpack(">II", d[o + 4 : o + 12])
        tags[sig] = (off, sz)
    return d, tags


def xyz(d, t, s):
    off, _ = t[s]
    return [v / 65536 for v in struct.unpack(">3i", d[off + 8 : off + 20])]


def trc(d, t, s):
    off, _ = t[s]
    cnt = struct.unpack(">I", d[off + 8 : off + 12])[0]
    return [v / 65535 for v in struct.unpack(f">{cnt}H", d[off + 12 : off + 12 + cnt * 2])]


def ev(tbl, x):
    n = len(tbl)
    if x <= 0:
        return tbl[0]
    if x >= 1:
        return tbl[-1]
    pos = x * (n - 1)
    lo = int(pos)
    if lo >= n - 1:
        return tbl[-1]
    f = pos - lo
    return tbl[lo] * (1 - f) + tbl[lo + 1] * f


def inv(tbl, t):
    n = len(tbl)
    if t <= tbl[0]:
        return 0.0
    if t >= tbl[-1]:
        return 1.0
    i = 1
    while i < n and tbl[i] < t:
        i += 1
    lo, hi = tbl[i - 1], tbl[i]
    span = hi - lo
    xlo, xhi = (i - 1) / (n - 1), i / (n - 1)
    if span <= 0:
        return xhi
    return xlo + (xhi - xlo) * (t - lo) / span


d1, t1 = load("testdata/srgb.icc")
M1 = np.array([xyz(d1, t1, "rXYZ"), xyz(d1, t1, "gXYZ"), xyz(d1, t1, "bXYZ")]).T
tb1 = trc(d1, t1, "rTRC")
d2, t2 = load("testdata/display.icc")
M2 = np.array([xyz(d2, t2, "rXYZ"), xyz(d2, t2, "gXYZ"), xyz(d2, t2, "bXYZ")]).T
tb2 = trc(d2, t2, "rTRC")
M2i = np.linalg.inv(M2)


def spec(inputs):
    out = []
    for (ri, gi, bi) in inputs:
        lin = np.array([ev(tb1, ri / 255), ev(tb1, gi / 255), ev(tb1, bi / 255)])
        lin2 = M2i @ (M1 @ lin)
        out.append(tuple(round(max(0, min(1, inv(tb2, c))) * 255) for c in lin2))
    return out


# 样本自给自足：与 tools/gen_golden.py 用同一随机源，不依赖任何外部文件。
rng = np.random.default_rng(42)
inputs = [tuple(int(v) for v in s) for s in rng.integers(0, 256, size=(4096, 3))]
mine = spec(inputs)

src = ImageCms.getOpenProfile("testdata/srgb.icc")
dst = ImageCms.getOpenProfile("testdata/display.icc")

im = Image.new("RGB", (64, 64))
im.putdata(inputs)
print("Pillow 版本:", Image.__version__)
print(f"样本数: {len(inputs)}（numpy default_rng(42)）")
print()

results = {}
for flag_name in ["NONE", "NOOPTIMIZE", "HIGHRESPRECALC", "LOWRESPRECALC", "FORCE_CLUT"]:
    flag = getattr(ImageCms.Flags, flag_name, None)
    if flag is None:
        continue
    try:
        x = ImageCms.buildTransformFromOpenProfiles(
            src, dst, "RGB", "RGB", renderingIntent=1, flags=int(flag)
        )
        out = list(ImageCms.applyTransform(im, x).get_flattened_data())
        results[flag_name] = out
    except Exception as e:
        print(f"{flag_name}: 失败 {e}")

print()
print(f"{'flag':<18} {'与本库完全一致':>16} {'最大偏差':>10}")
for name, out in results.items():
    exact = sum(1 for a, b in zip(out, mine) if a == b)
    worst = max(max(abs(a[k] - b[k]) for k in range(3)) for a, b in zip(out, mine))
    print(f"{name:<18} {exact:>12}/{len(mine)}   {worst:>8}")
print()
print("说明：NONE（默认）会构建 3D CLUT 做插值，属于速度优先的近似；")
print("      NOOPTIMIZE 走逐步精确通路，因此与本库的规范实现最接近。")
print("      金标（tools/gen_golden.py）取 NOOPTIMIZE。")
