"""刻画 link_golden 残余差异的性质，为判据提供依据。

从 link_golden_wbtest.mbt 读入金标，用按 ICC 规范逐字转写的双精度实现
算出本库应当输出的值，然后统计偏差，并检查偏差通道的目标线性值分布。
"""

import re, sys, struct

sys.stdout.reconfigure(encoding="utf-8")
import numpy as np


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

pat = re.compile(
    r"\{ r: (\d+), g: (\d+), b: (\d+), out_r: (\d+), out_g: (\d+), out_b: (\d+),? \}"
)
cases = []
for line in open("link_golden_wbtest.mbt", encoding="utf-8"):
    m = pat.search(line)
    if m:
        cases.append(tuple(int(x) for x in m.groups()))

if not cases:
    print("未从 link_golden_wbtest.mbt 读到任何用例，请先运行 tools/gen_golden.py")
    sys.exit(1)

print(f"读入金标 {len(cases)} 例")

devs = {0: 0, 1: 0, 2: 0, 3: 0, ">3": 0}
bad_channels = []
for (r, g, b, orr, og, ob) in cases:
    lin = np.array([ev(tb1, r / 255), ev(tb1, g / 255), ev(tb1, b / 255)])
    lin2 = M2i @ (M1 @ lin)
    mine = tuple(round(max(0, min(1, inv(tb2, c))) * 255) for c in lin2)
    ref = (orr, og, ob)
    d = max(abs(mine[k] - ref[k]) for k in range(3))
    devs[d if d <= 3 else ">3"] += 1
    for k in range(3):
        if mine[k] != ref[k]:
            bad_channels.append((lin2[k], ref[k], mine[k], (r, g, b), k))

print(f"偏差分布: {devs}")
print(f"完全一致 {devs[0]} / {len(cases)} = {devs[0]/len(cases)*100:.2f}%")
print()

lins = sorted(c[0] for c in bad_channels)
print(f"有偏差的通道共 {len(bad_channels)} 个")
print(f"这些通道的目标线性值：min={lins[0]:.3e}  中位={np.median(lins):.3e}  max={lins[-1]:.3e}")
n_neg = sum(1 for x in lins if x < 0)
print(f"其中负值（超出目标色域、被夹到 0）：{n_neg}")
print()
print("最大的 10 个线性值（即偏差出现位置的上界）:")
for x in lins[-10:]:
    tot = x * 65535
    print(f"  lin={x:.4e}  -> 16 位域 {tot:8.2f} 个量化级")
print()
print("偏差最大的几例:")
bad_channels.sort(key=lambda c: -abs(c[2] - c[1]))
for c in bad_channels[:6]:
    print(
        f"  输入{c[3]} 通道{c[4]}: 线性={c[0]:.4e} (16 位 {c[0]*65535:.2f} 级) "
        f"lcms2={c[1]} 本库={c[2]} 差={abs(c[2]-c[1])}"
    )
