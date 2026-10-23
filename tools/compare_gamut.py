#!/usr/bin/env python3
"""色域边界的独立对拍：Python + lcms2 的 Lab 值 vs 本库的 MoonBit 实现。

为什么需要它：lcms2 自带的色域边界描述符（GDB）API 实测不能作为 oracle
（`cmsGDBCheckPoint` 对全部查询都返回 out，见 CONFORMANCE.md 已知边界第 5 条）。
于是改用**独立第二实现**的思路：

  - 边界样本：用 **lcms2** 把 CMYK 9^4 = 6561 个设备网格点转成 Lab；
  - 球面直方图：在 **Python** 里按同一约定（中心 Lab(50,0,0)、16×16 扇区、
    记最大半径、查询时取 3×3 邻域最大值）重新实现一遍；
  - 查询色：用 **lcms2** 把 sRGB 角点与灰阶转成 Lab；
  - 与本库 CLI `gamut` 的输出逐点比对判定。

两边共用同一套**规范约定**，但代码路径（Lab 来源、语言、数据结构）完全独立，
因此一致率是有意义的交叉验证；不一致处会被逐条打印出来。

用法：python tools/compare_gamut.py [--steps 9]
"""

import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

from PIL import Image, ImageCms

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTDATA = os.path.join(ROOT, "testdata")
SECTORS = 16
NOOPT = ImageCms.Flags.NOOPTIMIZE | ImageCms.Flags.NOCACHE


def open_profile(name):
    return ImageCms.getOpenProfile(os.path.join(TESTDATA, name))


def lab_transform(src_name, src_mode):
    """lcms2：src_mode → Lab（D50）。只用输出方向，避开 8 位 Lab 输入编码的坑。"""
    lab = ImageCms.createProfile("LAB")
    return ImageCms.buildTransform(
        open_profile(src_name), lab, src_mode, "LAB",
        renderingIntent=1, flags=NOOPT,
    )


def lab_values(transform, mode, samples):
    """一批样本过 lcms2 → (L, a, b)。Pillow 的 LAB 是 8 位：L*255/100、a/b +128。"""
    data = bytes(b for s in samples for b in s)
    im = Image.frombytes(mode, (len(samples), 1), data)
    out = ImageCms.applyTransform(im, transform)
    px = list(out.get_flattened_data())
    return [(p[0] * 100.0 / 255.0, p[1] - 128.0, p[2] - 128.0) for p in px]


def spherical(lab):
    l, a, b = lab[0] - 50.0, lab[1], lab[2]
    r = (l * l + a * a + b * b) ** 0.5
    if r == 0:
        return r, 0.0, 0.0
    import math

    alpha = math.degrees(math.atan2(a, b))
    if alpha < 0:
        alpha += 360.0
    theta = math.degrees(math.atan2((a * a + b * b) ** 0.5, l))
    return r, alpha, theta


def sector_of(alpha, theta):
    ai = min(SECTORS - 1, max(0, int(alpha * SECTORS / 360.0)))
    ti = min(SECTORS - 1, max(0, int(theta * SECTORS / 180.0)))
    return ti * SECTORS + ai


def build_boundary(steps):
    """用 lcms2 的 Lab 值建球面直方图边界。"""
    tr = lab_transform("cmyk_printer.icc", "CMYK")
    samples = []
    levels = [i / (steps - 1) for i in range(steps)]
    for c in levels:
        for m in levels:
            for y in levels:
                for k in levels:
                    samples.append(
                        (
                            int(round(c * 255)), int(round(m * 255)),
                            int(round(y * 255)), int(round(k * 255)),
                        )
                    )
    labs = lab_values(tr, "CMYK", samples)
    radii = [0.0] * (SECTORS * SECTORS)
    filled = [False] * (SECTORS * SECTORS)
    for lab in labs:
        r, alpha, theta = spherical(lab)
        s = sector_of(alpha, theta)
        if not filled[s] or r > radii[s]:
            radii[s], filled[s] = r, True
    return radii, filled, len(labs)


def neighbourhood_max(radii, filled, sector):
    s = SECTORS
    ti, ai = divmod(sector, s)
    best, any_ = 0.0, False
    for dt in (-1, 0, 1):
        t = ti + dt
        if t < 0 or t >= s:
            continue
        for da in (-1, 0, 1):
            a = (ai + da) % s
            idx = t * s + a
            if filled[idx]:
                any_ = True
                best = max(best, radii[idx])
    return best, any_


def python_verdict(radii, filled, lab):
    r, alpha, theta = spherical(lab)
    rmax, any_ = neighbourhood_max(radii, filled, sector_of(alpha, theta))
    if not any_:
        return False, r
    return r <= rmax * 1.0000001, r - rmax


def query_samples():
    corners = [
        (0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0),
        (0, 0, 255), (0, 255, 255), (255, 0, 255), (255, 255, 0),
    ]
    grays = [(g, g, g) for g in range(0, 256, 17)]
    return corners + grays


def moonbit_verdicts(steps):
    """跑本库 CLI 的 gamut 子命令，解析判定与距离。"""
    out = subprocess.run(
        ["moon", "run", "cmd/main", "--target", "wasm-gc", "--", "gamut",
         os.path.join(TESTDATA, "srgb.icc"),
         os.path.join(TESTDATA, "cmyk_printer.icc"), "relative", str(steps)],
        cwd=ROOT, capture_output=True, encoding="utf-8", errors="replace",
    ).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r"gamut (\d+) (\d+) (\d+) (\d+) boundary=(\w+) dist=([-\d.eE+]+)", line)
        if m:
            rows[int(m.group(1))] = {
                "rgb": (int(m.group(2)), int(m.group(3)), int(m.group(4))),
                "in": m.group(5) == "in",
                "dist": float(m.group(6)),
            }
    return rows


def main():
    steps = 9
    if "--steps" in sys.argv:
        steps = int(sys.argv[sys.argv.index("--steps") + 1])
    print(f"独立对拍：lcms2 取 Lab + Python 球面直方图 vs 本库 MoonBit 实现（采样 {steps} 层）")

    radii, filled, n = build_boundary(steps)
    print(f"  Python 侧边界：{n} 个样本，非空扇区 {sum(filled)}/{SECTORS * SECTORS}")

    samples = query_samples()
    labs = lab_values(lab_transform("srgb.icc", "RGB"), "RGB", samples)
    ours = moonbit_verdicts(steps)
    if not ours:
        print("❌ 没能解析本库 CLI 的输出")
        return 1

    agree = 0
    disagree = []
    for i, lab in enumerate(labs):
        py_in, py_dist = python_verdict(radii, filled, lab)
        mb = ours.get(i)
        if mb is None:
            print(f"  本库缺少第 {i} 个样本的输出")
            return 1
        if py_in == mb["in"]:
            agree += 1
        else:
            disagree.append((i, mb["rgb"], py_in, py_dist, mb["in"], mb["dist"]))

    rate = agree / len(samples) * 100
    print(f"  一致 {agree}/{len(samples)} = {rate:.1f}%")
    for d in disagree:
        print(
            f"    不一致 #{d[0]} RGB{d[1]}: "
            f"Python={'in' if d[2] else 'out'}({d[3]:+.2f}) "
            f"本库={'in' if d[4] else 'out'}({d[5]:+.2f})"
        )
    # 判据：两个独立实现的分歧应很小；差异应集中在边界附近（|dist| 小）
    near = [d for d in disagree if abs(d[3]) < 3.0 or abs(d[5]) < 3.0]
    if rate < 90.0:
        print(f"❌ 一致率 {rate:.1f}% 低于 90%")
        return 1
    print(
        f"✅ 一致率 {rate:.1f}%（分歧 {len(disagree)} 个，其中 {len(near)} 个在边界 3 个 Lab 单位内）"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
