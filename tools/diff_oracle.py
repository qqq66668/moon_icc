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

PROFILES = ["srgb.icc", "display.icc", "cmyk_printer.icc"]


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
    cmd = ["moon", "run", "cmd/main", "--target", target, "--", path]
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

    if total_diffs:
        print(f"\n差分失败：共 {total_diffs} 处不一致")
        return 1
    print("\n差分通过：Python 独立解析与 MoonBit 库输出完全一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
