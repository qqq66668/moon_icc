#!/usr/bin/env python3
"""外部 oracle 差分：用 Python struct 独立解析 ICC profile，与 MoonBit 库的输出比对。

这是独立判据。被测实现与判据必须来源不同——
本脚本不调用库的任何代码路径，只读同一批真实 profile 文件，
按 ICC.1 规范自行解析，再与 `moon run cmd/main` 的输出逐字段比较。

判据必须能失败：把 header.mbt 里任意一个字段的偏移改错，本脚本应当报错。
"""

import struct
import subprocess
import sys
import os

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PROFILES = ["srgb.icc", "display.icc", "cmyk_printer.icc", "test4.icc"]

# 变换对拍的绝对容差。
#
# 取值依据（实测，非拍脑袋）：先用 1e-12 的哨兵值跑一次，量出实际离散度。
# 结果：3 个 profile × 15 个样本 × 3 个分量，**最大偏差 0.0（逐位一致）**。
# 两边都是 IEEE 754 双精度，输入是同一批整数（TRC 表的 u16 与矩阵的
# s15Fixed16），TRC 表插值与矩阵乘的运算顺序也一致，因此没有可观测分歧。
#
# 既然参考自身的离散度是 0，容差就设成一个仍能捕捉真实回归的紧值：
# 1e-15 足以容纳任何平台相关的末位舍入，同时让"中间调写错""顺序颠倒"
# 这类结构性错误（偏差量级 1e-2 以上）必然触发失败。
TOLERANCE = 1e-15


def parse_with_python(path):
    """按 ICC.1 规范独立解析，返回与 MoonBit CLI 相同结构的字典。"""
    with open(path, "rb") as f:
        d = f.read()

    size = struct.unpack(">I", d[0:4])[0]
    version = struct.unpack(">I", d[8:12])[0]
    major = (version >> 24) & 0xFF
    minor = (version >> 20) & 0x0F
    device_class = d[12:16].decode("ascii")
    color_space = d[16:20].decode("ascii")
    pcs = d[20:24].decode("ascii")

    y, mo, da, hh, mm, ss = struct.unpack(">6H", d[24:36])
    datetime_str = f"{y}-{mo:02d}-{da:02d}T{hh:02d}:{mm:02d}:{ss:02d}"

    intent = struct.unpack(">I", d[64:68])[0]

    # 照明体是 3 个 s15Fixed16，需按有符号解释，再除以 65536
    ix, iy, iz = struct.unpack(">3i", d[68:80])

    tag_count = struct.unpack(">I", d[128:132])[0]
    tags = []
    for i in range(tag_count):
        o = 132 + i * 12
        sig = d[o : o + 4].decode("ascii")
        off, sz = struct.unpack(">II", d[o + 4 : o + 12])
        tags.append((sig, off, sz))

    return {
        "size": size,
        "version": f"{major}.{minor}",
        "class": device_class,
        "colorspace": color_space,
        "pcs": pcs,
        "datetime": datetime_str,
        "intent": intent,
        "illuminant": (ix / 65536.0, iy / 65536.0, iz / 65536.0),
        "tagcount": tag_count,
        "tags": tags,
    }


def parse_with_moonbit(path, target):
    """跑 MoonBit CLI，解析其纯文本输出。"""
    cmd = ["moon", "run", "cmd/main", "--target", target, "--", "parse", path]
    r = subprocess.run(
        cmd, capture_output=True, encoding="utf-8", errors="replace", timeout=300
    )
    if r.returncode != 0:
        raise RuntimeError(f"MoonBit CLI 退出码 {r.returncode}\n{r.stdout}\n{r.stderr}")

    out = {"tags": []}
    for line in r.stdout.splitlines():
        line = line.rstrip("\r")
        if not line:
            continue
        # 注意：ICC 的 4 字节签名可能含尾随空格（如 "RGB "、"XYZ "、"Lab "），
        # 因此不能用 split() 取值——那会吃掉尾随空格，把库的正确输出误判为错误。
        # 这里按"首个空格"切分，保留其余部分原样（含尾随空格）。
        def field(prefix):
            """取 "prefix value" 中 prefix 之后的部分，保留尾随空格。"""
            assert line.startswith(prefix + " ")
            return line[len(prefix) + 1 :]

        if line.startswith("size "):
            out["size"] = int(field("size"))
        elif line.startswith("version "):
            out["version"] = field("version")
        elif line.startswith("class "):
            out["class"] = field("class")
        elif line.startswith("colorspace "):
            out["colorspace"] = field("colorspace")
        elif line.startswith("pcs "):
            out["pcs"] = field("pcs")
        elif line.startswith("datetime "):
            out["datetime"] = field("datetime")
        elif line.startswith("intent "):
            out["intent"] = int(field("intent"))
        elif line.startswith("illuminant "):
            parts = field("illuminant").split()
            out["illuminant"] = tuple(float(x) for x in parts[0:3])
        elif line.startswith("tagcount "):
            out["tagcount"] = int(field("tagcount"))
        else:
            parts = line.split()
            if len(parts) == 3:
                out["tags"].append((parts[0], int(parts[1]), int(parts[2])))
    return out


def parse_v4_lut_with_python(path):
    """独立解析 ICC v4 的 `mAB ` / `mBA ` tag 结构。

    与库的实现完全独立：只按 ICC.1 的字段布局读字节，并按**段长度自洽**
    做校验（每段都必须落在 tag 范围内，CLUT 的字节数必须等于
    网格点数乘积 × 输出通道数 × 精度）。

    返回 {tag: {...}}；没有 v4 LUT tag 时返回空字典。
    """
    with open(path, "rb") as f:
        d = f.read()

    n = struct.unpack(">I", d[128:132])[0]
    tags = {}
    for i in range(n):
        o = 132 + i * 12
        sig = d[o : o + 4].decode("latin1")
        off, sz = struct.unpack(">II", d[o + 4 : o + 12])
        tags[sig] = (off, sz)

    result = {}
    for tag in ("A2B0", "A2B1", "B2A0", "B2A1"):
        if tag not in tags:
            continue
        base, size = tags[tag]
        ttype = d[base : base + 4].decode("latin1")
        if ttype not in ("mAB ", "mBA "):
            continue
        ic, oc = d[base + 8], d[base + 9]
        o_b, o_mat, o_m, o_c, o_a = struct.unpack(">5I", d[base + 12 : base + 32])
        tag_end = base + size

        def read_curves(off, count):
            """按类型从内容推算段长（内嵌曲线**没有**长度字段）。"""
            if off == 0:
                return []
            p = base + off
            out = []
            for _ in range(count):
                sig = d[p : p + 4].decode("latin1")
                if sig == "curv":
                    cnt = struct.unpack(">I", d[p + 8 : p + 12])[0]
                    step = 12 if cnt == 0 else (14 if cnt == 1 else 12 + 2 * cnt)
                    out.append(("curv", cnt))
                elif sig == "para":
                    ft = struct.unpack(">H", d[p + 8 : p + 10])[0]
                    npar = (1, 3, 4, 5, 7)[ft]
                    step = 12 + 4 * npar
                    out.append(("para", ft, npar))
                else:
                    raise SystemExit(f"{tag}: 内嵌曲线类型 {sig!r} 无法解析")
                if p + step > tag_end:
                    raise SystemExit(f"{tag}: 曲线段越出 tag 范围")
                p = (p + step + 3) // 4 * 4
            return out

        if ttype == "mAB ":
            # 设备 → PCS：A 用输入通道数，M/B 用输出通道数
            a_cnt, m_cnt, b_cnt = ic, oc, oc
        else:
            # PCS → 设备：B/M 用输入通道数，A 用输出通道数
            b_cnt, m_cnt, a_cnt = ic, ic, oc

        curves = {
            "A": read_curves(o_a, a_cnt),
            "M": read_curves(o_m, m_cnt),
            "B": read_curves(o_b, b_cnt),
        }

        matrix = None
        if o_mat:
            if base + o_mat + 48 > tag_end:
                raise SystemExit(f"{tag}: 矩阵段越出 tag 范围")
            matrix = struct.unpack(">12i", d[base + o_mat : base + o_mat + 48])

        grid = prec = nodes = None
        if o_c:
            cp = base + o_c
            grid = list(d[cp : cp + ic])
            prec = d[cp + 16]
            npts = 1
            for g in grid:
                npts *= g
            nodes = npts * oc
            if cp + 20 + nodes * prec > tag_end:
                raise SystemExit(f"{tag}: CLUT 段越出 tag 范围")
        result[tag] = {
            "type": ttype,
            "ic": ic,
            "oc": oc,
            "grid": grid,
            "prec": prec,
            "nodes": nodes,
            "curves": curves,
            "matrix": matrix,
        }
    return result


def lut_with_moonbit(path, target):
    """跑 CLI 的 lut 子命令，取出 a2b_* / b2a_* 结构字段。"""
    cmd = ["moon", "run", "cmd/main", "--target", target, "--", "lut", path]
    r = subprocess.run(
        cmd, capture_output=True, encoding="utf-8", errors="replace", timeout=300
    )
    if r.returncode != 0:
        raise RuntimeError(f"MoonBit CLI 退出码 {r.returncode}\n{r.stdout}\n{r.stderr}")
    out = {}
    for line in r.stdout.splitlines():
        line = line.rstrip("\r")
        for prefix in ("a2b_", "b2a_"):
            if line.startswith(prefix):
                key, _, value = line.partition(" ")
                out[key] = value
    return out


def compare_v4_structure(name, py, mb):
    """把 Python 独立解析的 v4 结构与库的 lut 输出比对。

    CLI 的 `lut` 子命令打印的是 **intent=1** 的表，即 `A2B1` / `B2A1`。
    """
    diffs = []
    for tag, key in (("A2B1", "a2b"), ("B2A1", "b2a")):
        if tag not in py:
            diffs.append(f"  Python 未找到 {tag}")
            continue
        info = py[tag]
        want = {
            f"{key}_type": info["type"],
            f"{key}_input_channels": str(info["ic"]),
            f"{key}_output_channels": str(info["oc"]),
            f"{key}_grid_points": "x".join(str(g) for g in (info["grid"] or [])),
        }
        if info["grid"] is None:
            want[f"{key}_grid_points"] = "无 CLUT"
        for k, v in want.items():
            if mb.get(k) != v:
                diffs.append(f"  {k}: python={v!r} moonbit={mb.get(k)!r}")
    return diffs


def compare(name, py, mb):
    """逐字段比对，返回差异列表。"""
    diffs = []
    for key in ["size", "version", "class", "colorspace", "pcs", "datetime", "intent"]:
        if py[key] != mb.get(key):
            diffs.append(f"  {key}: python={py[key]!r} moonbit={mb.get(key)!r}")

    # 浮点字段用精确比较：两边都是同一整数除以 65536，
    # 二进制表示应当完全一致，不需要容差。
    for i, axis in enumerate("xyz"):
        if py["illuminant"][i] != mb["illuminant"][i]:
            diffs.append(
                f"  illuminant.{axis}: python={py['illuminant'][i]!r} "
                f"moonbit={mb['illuminant'][i]!r}"
            )

    if py["tagcount"] != mb["tagcount"]:
        diffs.append(f"  tagcount: python={py['tagcount']} moonbit={mb.get('tagcount')}")

    if len(py["tags"]) != len(mb["tags"]):
        diffs.append(
            f"  tag 数量: python={len(py['tags'])} moonbit={len(mb['tags'])}"
        )
    else:
        for i, (a, b) in enumerate(zip(py["tags"], mb["tags"])):
            if a != b:
                diffs.append(f"  tag[{i}]: python={a} moonbit={b}")
    return diffs


def transform_with_python(path):
    """用 Python 独立实现 matrix/TRC 变换，返回 {v: (X, Y, Z)}。

    这是功能 2 的独立判据：不调用库的任何代码，
    按 ICC.1 规范自行读 TRC 表、套矩阵。

    只支持 matrix/TRC 型 profile（有 rXYZ/gXYZ/bXYZ/rTRC/gTRC/bTRC）。
    LUT 型（如 CMYK 打印机）返回 None。
    """
    with open(path, "rb") as f:
        d = f.read()

    n = struct.unpack(">I", d[128:132])[0]
    tags = {}
    for i in range(n):
        o = 132 + i * 12
        sig = d[o : o + 4].decode("ascii")
        off, sz = struct.unpack(">II", d[o + 4 : o + 12])
        tags[sig] = (off, sz)

    needed = ["rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC"]
    if any(k not in tags for k in needed):
        return None

    def read_xyz(sig):
        off, _ = tags[sig]
        assert d[off : off + 4] == b"XYZ "
        return struct.unpack(">3i", d[off + 8 : off + 20])

    # 矩阵按列存：三列分别是 rXYZ/gXYZ/bXYZ
    cols = [read_xyz("rXYZ"), read_xyz("gXYZ"), read_xyz("bXYZ")]
    M = [[v / 65536.0 for v in c] for c in cols]

    def read_trc(sig):
        """返回一个求值函数 v -> linear。"""
        off, _ = tags[sig]
        ttype = d[off : off + 4]
        if ttype == b"curv":
            cnt = struct.unpack(">I", d[off + 8 : off + 12])[0]
            if cnt == 0:
                return lambda x: x
            if cnt == 1:
                g = struct.unpack(">H", d[off + 12 : off + 14])[0] / 256.0
                return lambda x: x**g
            tbl = struct.unpack(f">{cnt}H", d[off + 12 : off + 12 + cnt * 2])
            tbl = [v / 65535.0 for v in tbl]

            def ev(x):
                if x <= 0:
                    return tbl[0]
                if x >= 1:
                    return tbl[-1]
                pos = x * (cnt - 1)
                lo = int(pos)
                if lo >= cnt - 1:
                    return tbl[-1]
                frac = pos - lo
                return tbl[lo] * (1 - frac) + tbl[lo + 1] * frac

            return ev
        raise NotImplementedError(f"未支持的 TRC 类型 {ttype!r}")

    trcs = [read_trc("rTRC"), read_trc("gTRC"), read_trc("bTRC")]

    def to_xyz(v):
        lin = [trcs[0](v), trcs[1](v), trcs[2](v)]
        return (
            M[0][0] * lin[0] + M[1][0] * lin[1] + M[2][0] * lin[2],
            M[0][1] * lin[0] + M[1][1] * lin[1] + M[2][1] * lin[2],
            M[0][2] * lin[0] + M[1][2] * lin[1] + M[2][2] * lin[2],
        )

    return {v: to_xyz(v) for v in SAMPLES}


SAMPLES = [
    0.0,
    0.05,
    0.1,
    0.2,
    0.25,
    0.3,
    0.4,
    0.5,
    0.6,
    0.7,
    0.75,
    0.8,
    0.9,
    0.95,
    1.0,
]


def transform_with_moonbit(path, target):
    """跑 CLI 的 transform 子命令，返回 {v: (X, Y, Z)}。"""
    cmd = ["moon", "run", "cmd/main", "--target", target, "--", "transform", path]
    r = subprocess.run(
        cmd, capture_output=True, encoding="utf-8", errors="replace", timeout=300
    )
    if r.returncode != 0:
        raise RuntimeError(f"MoonBit CLI 退出码 {r.returncode}\n{r.stdout}\n{r.stderr}")
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 8 and parts[0] == "sample":
            v = float(parts[1])
            out[v] = (float(parts[2]), float(parts[3]), float(parts[4]))
    return out


def compare_transforms(py, mb, tol):
    """比对变换结果，返回差异列表。

    容差来源：两边都是 IEEE 754 双精度、同一批整数输入，
    差异只应来自浮点舍入与库函数的实现差异（pow/cbrt）。
    这里用绝对容差，且容差取值由实测离散度决定，不拍脑袋。
    """
    diffs = []
    if len(py) != len(mb):
        diffs.append(f"  样本数: python={len(py)} moonbit={len(mb)}")
        return diffs
    worst = 0.0
    for v in py:
        if v not in mb:
            diffs.append(f"  样本 {v} 在 MoonBit 输出中缺失")
            continue
        for i, axis in enumerate("XYZ"):
            a, b = py[v][i], mb[v][i]
            dev = abs(a - b)
            worst = max(worst, dev)
            if dev > tol:
                diffs.append(
                    f"  样本 v={v} {axis}: python={a!r} moonbit={b!r} 差={dev:.3e}"
                )
    return diffs, worst


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "wasm-gc"
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)

    total_diffs = 0
    for name in PROFILES:
        path = os.path.join(root, "testdata", name)
        if not os.path.exists(path):
            print(f"跳过 {name}：文件不存在（{path}）")
            continue
        py = parse_with_python(path)
        mb = parse_with_moonbit(path, target)
        diffs = compare(name, py, mb)
        if diffs:
            total_diffs += len(diffs)
            print(f"[不一致] {name}")
            for line in diffs:
                print(line)
        else:
            print(
                f"[一致] {name}: 头部 9 个字段 + {py['tagcount']} 个 tag 条目全部吻合"
            )

        # ---- 功能 4：v4 LUT（mAB / mBA）结构对拍 ----
        py_v4 = parse_v4_lut_with_python(path)
        if py_v4:
            mb_lut = lut_with_moonbit(path, target)
            v4_diffs = compare_v4_structure(name, py_v4, mb_lut)
            if v4_diffs:
                total_diffs += len(v4_diffs)
                print(f"[v4 结构不一致] {name}")
                for line in v4_diffs:
                    print(line)
            else:
                for tag in ("A2B1", "B2A1"):
                    info = py_v4[tag]
                    curves = "/".join(
                        f"{k}{len(v)}" for k, v in info["curves"].items()
                    )
                    grid = (
                        "无 CLUT"
                        if info["grid"] is None
                        else "x".join(str(g) for g in info["grid"])
                    )
                    print(
                        f"[v4 结构一致] {name} {tag}: {info['type']} "
                        f"{info['ic']}→{info['oc']} 网格 {grid} "
                        f"精度 {info['prec']} 曲线 {curves} "
                        f"矩阵项 {len(info['matrix']) if info['matrix'] else 0}"
                    )

        # ---- 功能 2：matrix/TRC 变换对拍 ----
        py_t = transform_with_python(path)
        if py_t is None:
            print(f"[跳过] {name}: 非 matrix/TRC 型 profile，不做变换对拍")
            continue
        mb_t = transform_with_moonbit(path, target)
        result = compare_transforms(py_t, mb_t, TOLERANCE)
        if isinstance(result, tuple):
            t_diffs, worst = result
        else:
            t_diffs, worst = result, float("inf")
        if t_diffs:
            total_diffs += len(t_diffs)
            print(f"[变换不一致] {name}")
            for line in t_diffs:
                print(line)
        else:
            print(
                f"[变换一致] {name}: {len(py_t)} 个样本 × 3 个分量，"
                f"最大偏差 {worst:.3e}（容差 {TOLERANCE:.1e}）"
            )

    if total_diffs:
        print(f"\n差分失败：共 {total_diffs} 处不一致")
        return 1
    print("\n差分通过：Python 独立实现与 MoonBit 库输出完全一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
