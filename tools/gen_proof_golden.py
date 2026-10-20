#!/usr/bin/env python3
"""生成软打样链的 lcms2 金标。

软打样（soft proofing）没有 Pillow 接口，因此这里直接调用 lcms2 的
`cmsCreateProofingTransform`：

1. 用 `_research/lcms_probe` 下的 Little-CMS 源码 + MSYS2 gcc 编译出
   `lcms2_proof.exe`（若已存在则跳过）；
2. 对给定意图组合跑固定样本（步长 17 的灰阶，与 CLI 的 `proof` 命令一致）；
3. 把结果量化到 0..255，写成 MoonBit 金标文件 `proof_golden_wbtest.mbt`。

用法：
    python tools/gen_proof_golden.py
"""

import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LCMS = os.path.normpath(os.path.join(ROOT, "..", "_research", "lcms_probe"))
SRC = os.path.join(LCMS, "Little-CMS-master")
BUILD = os.path.join(LCMS, "build")
EXE = os.path.join(BUILD, "lcms2_proof.exe")
DRIVER = os.path.join(LCMS, "lcms2_proof.c")
TESTDATA = os.path.join(ROOT, "testdata")

GCC_CANDIDATES = [
    r"D:\msys64\ucrt64\bin\gcc.exe",
    "gcc",
]

# (意图, 打样意图) —— 覆盖「相对/相对」与「相对/绝对打样」
CASES = [(1, 1), (1, 3)]


def find_gcc():
    for c in GCC_CANDIDATES:
        if os.path.isabs(c):
            if os.path.exists(c):
                return c
        else:
            from shutil import which

            p = which(c)
            if p:
                return p
    return None


def ensure_exe():
    if os.path.exists(EXE):
        print(f"  复用已构建的 {os.path.basename(EXE)}")
        return True
    if not os.path.isdir(SRC):
        print(f"  找不到 Little-CMS 源码: {SRC}")
        return False
    gcc = find_gcc()
    if gcc is None:
        print("  找不到 gcc（MSYS2），无法构建对拍驱动")
        return False
    os.makedirs(BUILD, exist_ok=True)
    # 先构建 lcms2 动态库，再构建驱动
    dll = os.path.join(BUILD, "lcms2.dll")
    if not os.path.exists(dll):
        sources = [
            os.path.join(SRC, "src", f)
            for f in os.listdir(os.path.join(SRC, "src"))
            if f.endswith(".c")
        ]
        env = dict(os.environ)
        env["PATH"] = os.path.dirname(gcc) + os.pathsep + env.get("PATH", "")
        r = subprocess.run(
            [gcc, "-O2", "-shared", "-I", os.path.join(SRC, "include"), *sources,
             "-o", dll, "-lm"],
            capture_output=True, encoding="utf-8", errors="replace", env=env,
        )
        if r.returncode != 0:
            print("  lcms2 编译失败:\n" + (r.stderr or "")[-800:])
            return False
        print(f"  已构建 {os.path.basename(dll)}")
    env = dict(os.environ)
    env["PATH"] = BUILD + os.pathsep + os.path.dirname(gcc) + os.pathsep + env.get("PATH", "")
    r = subprocess.run(
        [gcc, "-O2", "-I", os.path.join(SRC, "include"), DRIVER,
         "-L", BUILD, "-llcms2", "-o", EXE],
        capture_output=True, encoding="utf-8", errors="replace", env=env,
    )
    if r.returncode != 0:
        print("  驱动编译失败:\n" + (r.stderr or "")[-800:])
        return False
    print(f"  已构建 {os.path.basename(EXE)}")
    return True


def run_case(intent, proof_intent):
    env = dict(os.environ)
    gcc = find_gcc()
    if gcc:
        env["PATH"] = BUILD + os.pathsep + os.path.dirname(gcc) + os.pathsep + env.get("PATH", "")
    r = subprocess.run(
        [EXE,
         os.path.join(TESTDATA, "srgb.icc"),
         os.path.join(TESTDATA, "cmyk_printer.icc"),
         os.path.join(TESTDATA, "display.icc"),
         str(intent), str(proof_intent)],
        capture_output=True, encoding="utf-8", errors="replace", env=env,
    )
    if r.returncode != 0:
        raise SystemExit("  对拍驱动运行失败:\n" + (r.stdout or "") + (r.stderr or ""))
    rows = []
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) != 5 or parts[0] != "proof":
            continue
        index = int(parts[1])
        vals = [float(x) for x in parts[2:5]]
        rows.append((index, [quantise(v) for v in vals]))
    return rows


def quantise(x):
    v = x * 255.0
    return int(v + 0.5) if v >= 0 else 0


def main():
    print("生成软打样金标（lcms2 cmsCreateProofingTransform）")
    if not ensure_exe():
        return 1
    out = []
    out.append("///|")
    out.append("/// 软打样链的 lcms2 金标（自动生成，勿手改）。")
    out.append("///")
    out.append("/// 生成器：`tools/gen_proof_golden.py`，调用 lcms2 的")
    out.append("/// `cmsCreateProofingTransform`（`SOFTPROOFING | NOOPTIMIZE`）。")
    out.append("/// 链路：sRGB → 模拟 Agfa SWOP CMYK → 显示器 profile。")
    out.append("/// 样本：步长 17 的灰阶（与 CLI 的 `proof` 命令一致），量化到 0..255。")
    for intent, proof_intent in CASES:
        rows = run_case(intent, proof_intent)
        print(f"  intent={intent} proof_intent={proof_intent}: {len(rows)} 行")
        out.append("")
        out.append("///|")
        out.append(
            f"/// 打样金标：意图 {intent}、打样意图 {proof_intent}，"
            f"{len(rows)} 个样本。"
        )
        out.append(
            f"let proof_golden_{intent}_{proof_intent} : "
            f"Array[(Int32, Int32, Int32, Int32)] = ["
        )
        for index, rgb in rows:
            out.append(f"  ({index}, {rgb[0]}, {rgb[1]}, {rgb[2]}),")
        out.append("]")
    path = os.path.join(ROOT, "proof_golden_wbtest.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"已写出 {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
