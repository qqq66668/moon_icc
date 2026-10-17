#!/usr/bin/env python3
"""把 README 里的 MoonBit 示例**真的跑一遍**。

为什么要做：README 示例是评审的第一入口，但示例代码最容易"看起来对、照抄就错"
——导入写在 `moon.pkg` 而不是 `.mbt`、函数需要 `raise`、包别名与路径不一致……
AGENTS.md 明确要求：**README 示例必须在全新临时工程里 `moon add` 后实跑一遍**。

做法：

1. 从 `README.md` 抽出所有 ```moonbit 代码块；
2. 在**仓库之外**新建空工程（`_research/readme_examples/`），
   `moon add qqq66668/moon_icc` 从 mooncakes.io 实拉（也可用 `--local` 指向本仓库，
   但 `moon.work` 不接受非版本化导入，因此这里只走真实拉取）；
3. 把示例里引用到的 profile 按**示例中的文件名**拷进工程
   （`sRGB Color Space Profile.icc` / `display.icc` / `printer.icc`）；
4. 每个代码块包成一个函数顺次调用，编译并运行；
5. 断言运行成功，并把输出里出现的文档化数值（如中间调 XYZ）与 README 核对。

用法：
    python tools/check_readme_examples.py
退出码非 0 表示有示例跑不通。
"""

import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.normpath(os.path.join(ROOT, "..", "_research", "readme_examples"))
README = os.path.join(ROOT, "README.md")

# 示例里用到的文件名 → 仓库内的真实文件
PROFILE_ALIASES = {
    "sRGB Color Space Profile.icc": "srgb.icc",
    "display.icc": "display.icc",
    "printer.icc": "cmyk_printer.icc",
}

# README 中公布的期望数值：生成代码会重算并打印 CHECK_ 前缀行，由本脚本比对。
# 容差取 1e-15：与仓库其他对拍判据同口径（参考自身的离散度是 0，取一个仍能
# 捕捉真实回归的紧值）。
DOCUMENTED = {
    "XYZ": (0.20640003241890215, 0.21403939749252843, 0.17660683523992873),
}
TOL = 1e-15

MOON_PKG = """import {
  "qqq66668/moon_icc",
  "moonbitlang/x/fs",
}

pkgtype(kind: "executable")
"""


def extract_blocks():
    text = open(README, encoding="utf-8").read()
    blocks = []
    for lang, body in re.findall(r"```(\w*)\n(.*?)```", text, re.S):
        if lang == "moonbit":
            blocks.append(body.rstrip())
    return blocks


def build_program(blocks):
    """每个代码块包成一个函数，避免不同块之间的变量重名。"""
    out = ["///|", "/// 由 tools/check_readme_examples.py 自动生成：README 示例逐块执行。", ""]
    for i, body in enumerate(blocks):
        out.append(f"///|")
        out.append(f"/// README 示例块 #{i}")
        out.append(f"fn example_{i}() -> Unit raise {{")
        for line in body.splitlines():
            out.append("  " + line if line.strip() else "")
        out.append("}")
        out.append("")
    out.append("///|")
    out.append("/// 重算 README 中公布的数值（`CHECK_` 前缀行由本脚本比对）")
    out.append("fn documented_values() -> Unit raise {")
    out.append(
        '  let profile = @moon_icc.Profile::parse('
        '@fs.read_file_to_bytes("sRGB Color Space Profile.icc"))'
    )
    out.append("  let xyz = profile.matrix_trc().to_pcs(0.5, 0.5, 0.5)")
    out.append('  println("CHECK_XYZ \\{xyz.x} \\{xyz.y} \\{xyz.z}")')
    out.append("}")
    out.append("")
    out.append("///|")
    out.append("fn main raise {")
    for i in range(len(blocks)):
        out.append(f'  println("--- example_{i} ---")')
        out.append(f"  example_{i}()")
    out.append('  println("--- documented_values ---")')
    out.append("  documented_values()")
    out.append("}")
    return "\n".join(out) + "\n"


def run(cmd, cwd, timeout=900):
    r = subprocess.run(
        cmd, cwd=cwd, capture_output=True, encoding="utf-8",
        errors="replace", timeout=timeout,
    )
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    blocks = extract_blocks()
    print(f"从 README 抽出 {len(blocks)} 个 moonbit 代码块")
    if not blocks:
        print("❌ 没抽到代码块")
        return 1

    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(os.path.join(WORK, "cmd", "main"))
    with open(os.path.join(WORK, "moon.mod"), "w", encoding="utf-8") as f:
        f.write('name = "verify/readme_examples"\n\nversion = "0.0.1"\n')
    with open(os.path.join(WORK, "cmd", "main", "moon.pkg"), "w", encoding="utf-8") as f:
        f.write(MOON_PKG)
    with open(os.path.join(WORK, "cmd", "main", "main.mbt"), "w", encoding="utf-8") as f:
        f.write(build_program(blocks))
    for alias, real in PROFILE_ALIASES.items():
        src = os.path.join(ROOT, "testdata", real)
        if os.path.exists(src):
            shutil.copy(src, os.path.join(WORK, alias))

    print("[1/3] moon add qqq66668/moon_icc（从 mooncakes.io 实拉）")
    code, out = run(["moon", "add", "qqq66668/moon_icc"], WORK)
    if code != 0:
        print("❌ moon add 失败：\n" + out[-500:])
        return 1
    code, out = run(["moon", "add", "moonbitlang/x"], WORK)
    if code != 0:
        print("❌ 添加 moonbitlang/x 失败：\n" + out[-300:])
        return 1

    print("[2/3] 编译并运行 README 示例")
    code, out = run(["moon", "run", "cmd/main", "--target", "wasm-gc"], WORK)
    tail = out.strip().splitlines()
    print("      " + "\n      ".join(tail[-25:]))
    if code != 0:
        print("❌ README 示例跑不通（这正是 AGENTS.md 警告的'照抄就错'）")
        return 1

    print("[3/3] 核对 README 中公布的数值")
    fails = []
    m = re.search(r"CHECK_XYZ ([\d.eE+-]+) ([\d.eE+-]+) ([\d.eE+-]+)", out)
    if not m:
        fails.append("输出里没有 CHECK_XYZ 行")
    else:
        got = tuple(float(x) for x in m.groups())
        for i, axis in enumerate("XYZ"):
            want = DOCUMENTED["XYZ"][i]
            if abs(got[i] - want) > TOL:
                fails.append(
                    f"XYZ.{axis}: README 写 {want!r}，实际 {got[i]!r}"
                    f"（差 {abs(got[i] - want):.3e}）"
                )
    if fails:
        print("❌ 数值核对失败：")
        for f in fails:
            print("   - " + f)
        return 1
    print(f"      ✅ README 公布的中间调 XYZ 与示例实际输出一致（容差 {TOL:.0e}）")
    print(f"✅ {len(blocks)} 个 README 示例在全新工程里全部跑通")
    return 0


if __name__ == "__main__":
    sys.exit(main())
