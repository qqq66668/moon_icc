#!/usr/bin/env python3
"""发布后的独立验证：在**全新工程**里实拉已发布的包，编译并跑真实变换。

为什么必须这样做：`moon publish` 的命令回显只说明"上传成功"，
不能证明**别人拿到这个包能用**——依赖声明、`moon.pkg` 的导入、
导出接口的可见性都可能在打包环节出问题（README 示例若照抄报错，
评审端一定会踩到）。

本脚本做四件事：

1. 在**仓库之外**新建一个空工程（`_research/verify_publish/`，每次清空重建）；
2. `moon add qqq66668/moon_icc` 从 mooncakes.io 实拉；
3. 编译并运行一段真实代码：解析 sRGB profile、做中间调 matrix/TRC 变换、
   走一遍 CMYK 打印机的 LUT 变换；
4. 把结果与**本仓库已验证过的期望值**比对（中间调 XYZ 与 README 里
   公布的数字一致，容差 1e-12）。

用法：
    python tools/verify_publish.py [期望版本]

不传版本则拉最新版。退出码非 0 表示验证失败。

## 冒烟程序本身怎么先验证

发布前无法用本地路径替换依赖（`moon.work` 工作区不接受非版本化的 `import`），
因此发布前是把同一段代码临时放进仓库的 `cmd/_smoke/` 跑一次
（`moon run cmd/_smoke`，跑完删除）——2026-10-17 已这样验证过：
`xyz` 输出与 README 公布的期望值逐位一致，K 轴 L 从 100.39 单调降到 12.87。
那次实跑还发现 `fn main` 必须写成 `fn main raise`（否则调用会抛错的
API 编译不过），模板已按此修正。
"""

import os
import re
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.normpath(os.path.join(ROOT, "..", "_research", "verify_publish"))
MOD = "qqq66668/moon_icc"

# README「变换到 PCS」一节公布的实测值（sRGB 中灰 0.5,0.5,0.5 → PCS XYZ）
EXPECT_XYZ = (0.20640003241890215, 0.21403939749252843, 0.17660683523992873)
TOL = 1e-12

MAIN_MBT = """///|
/// 冒烟程序：只使用公开 API，验证已发布的包能独立使用。
///
/// 注意必须是 `fn main raise`：这里的每个调用都可能抛 `IccError`，
/// 写成 `fn main` 编译器会直接拒绝（这条是实跑时踩到的）。
fn main raise {
  let data = @fs.read_file_to_bytes("srgb.icc")
  let header = @moon_icc.parse_header(data)
  let tags = @moon_icc.parse_tag_table(data, header)
  println("class \\{header.device_class}")
  println("colorspace \\{header.color_space}")
  println("pcs \\{header.pcs}")
  println("tagcount \\{tags.length()}")
  let profile = @moon_icc.Profile::parse(data)
  let tr = profile.matrix_trc()
  let xyz = tr.to_pcs(0.5, 0.5, 0.5)
  println("xyz \\{xyz.x} \\{xyz.y} \\{xyz.z}")
  let lab = @moon_icc.xyz_to_lab(xyz)
  println("lab \\{lab.l} \\{lab.a} \\{lab.b}")
  // LUT 型（CMYK 打印机）走一遍，覆盖 v2 的 mft2 与 Lab 解码
  let cmyk = @moon_icc.Profile::parse(@fs.read_file_to_bytes("cmyk_printer.icc"))
  for k = 0; k <= 255; k = k + 51 {
    let v = k.to_double() / 255.0
    let l = cmyk.device_to_lab(1, [0.0, 0.0, 0.0, v])
    println("k \\{k} \\{l.l} \\{l.a} \\{l.b}")
  }
}
"""

MOON_PKG = """import {
  "qqq66668/moon_icc",
  "moonbitlang/x/fs",
}

pkgtype(kind: "executable")
"""


def run(cmd, cwd, timeout=900):
    r = subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def main():
    version = sys.argv[1] if len(sys.argv) > 1 else None
    spec = f"{MOD}@{version}" if version else MOD

    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    # 全新工程：名字与依赖都由本脚本生成（依赖通过 moon add 写入）
    with open(os.path.join(WORK, "moon.mod"), "w", encoding="utf-8") as f:
        f.write('name = "verify/publish_smoke"\n\nversion = "0.0.1"\n')
    os.makedirs(os.path.join(WORK, "cmd", "main"))
    with open(os.path.join(WORK, "cmd", "main", "moon.pkg"), "w", encoding="utf-8") as f:
        f.write(MOON_PKG)
    with open(os.path.join(WORK, "cmd", "main", "main.mbt"), "w", encoding="utf-8") as f:
        f.write(MAIN_MBT)
    for name in ("srgb.icc", "cmyk_printer.icc"):
        shutil.copy(os.path.join(ROOT, "testdata", name), os.path.join(WORK, name))

    print(f"[1/4] 全新工程：{WORK}")
    print(f"[2/4] moon add {spec} / moonbitlang/x")
    code, out = run(["moon", "add", spec], WORK)
    print("      " + out.strip().replace("\n", "\n      ")[-500:])
    if code != 0:
        print("❌ moon add 失败——包可能不存在或依赖声明有问题")
        return 1
    code, out = run(["moon", "add", "moonbitlang/x"], WORK)
    print("      " + out.strip().replace("\n", "\n      ")[-300:])
    if code != 0:
        print("❌ 添加 moonbitlang/x 失败")
        return 1

    print("[3/4] moon run cmd/main")
    code, out = run(["moon", "run", "cmd/main", "--target", "wasm-gc"], WORK)
    print("      " + out.strip().replace("\n", "\n      ")[-800:])
    if code != 0:
        print("❌ 运行失败——已发布的包在全新工程里不可用")
        return 1

    print("[4/4] 与仓库内已验证的期望值比对")
    fails = []
    m = re.search(r"class (\S+)", out)
    if not m or m.group(1) != "mntr":
        fails.append(f"device_class 期望 mntr，实得 {m.group(1) if m else '缺失'}")
    m = re.search(r"tagcount (\d+)", out)
    if not m or int(m.group(1)) != 17:
        fails.append(f"tagcount 期望 17，实得 {m.group(1) if m else '缺失'}")
    m = re.search(r"xyz ([\d.eE+-]+) ([\d.eE+-]+) ([\d.eE+-]+)", out)
    if not m:
        fails.append("输出里没有 xyz 行")
    else:
        got = tuple(float(x) for x in m.groups())
        for i, axis in enumerate("XYZ"):
            if abs(got[i] - EXPECT_XYZ[i]) > TOL:
                fails.append(
                    f"{axis}: 期望 {EXPECT_XYZ[i]!r} 实得 {got[i]!r}（差 {abs(got[i] - EXPECT_XYZ[i]):.3e}）"
                )
    # LUT 路径：K 从 0 到 100% 的 L 必须单调下降且落在 [0,100]
    ks = [(int(a), float(b)) for a, b in re.findall(r"k (\d+) ([\d.eE+-]+)", out)]
    if len(ks) < 5:
        fails.append(f"K 轴扫描输出不足：{len(ks)} 行")
    else:
        ls = [l for _, l in ks]
        if any(l < -0.5 or l > 101.0 for l in ls):
            fails.append(f"L 超出合理范围：{ls}")
        if any(ls[i] < ls[i + 1] - 0.5 for i in range(len(ls) - 1)):
            fails.append(f"L 未随墨量单调下降：{ls}")

    if fails:
        print("❌ 验证失败：")
        for f in fails:
            print("   - " + f)
        return 1
    print("✅ 已发布的包在全新工程里可独立使用，结果与仓库内期望值一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
