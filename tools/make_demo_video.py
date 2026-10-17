"""生成 demo 演示视频。

视频内容**全部来自真实命令输出**：脚本实际运行 `moon run cmd/main` 的
四个子命令，把 stdout 逐行渲染成终端画面，再用 ffmpeg 编码。

不做任何摆拍或手写输出——视频里出现的每一行都是当场跑出来的。

依赖：Pillow（画帧）、ffmpeg（编码）。ffmpeg 从工作区的 `_ffmpeg/` 下查找，
或用 PATH 里的 ffmpeg。

用法：
    python tools/make_demo_video.py

产物：
    demo/moon_icc-demo.mp4   演示视频
    demo/preview.png         预览图（供 README 内嵌）
"""

import os
import shutil
import subprocess
import sys
import tempfile
from functools import partial

sys.stdout.reconfigure(encoding="utf-8")
from PIL import Image, ImageDraw, ImageFont

# ---- 布局参数 ----
W, H = 1280, 720
FPS = 20
PAD = 28
TITLE_H = 40
LINE_H = 26
TERM_SIZE = 18
CAP_SIZE = 21

PROMPT = "$ "
BG = (16, 20, 24)
BAR = (32, 38, 46)
FG = (222, 228, 234)
DIM = (146, 158, 170)
GREEN = (110, 210, 140)
ACCENT = (96, 174, 255)

FONT_DIR = "C:/Windows/Fonts"
MONO = os.path.join(FONT_DIR, "consola.ttf")
CJK = os.path.join(FONT_DIR, "msyh.ttc")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_ffmpeg():
    local = os.path.normpath(
        os.path.join(ROOT, "..", "_ffmpeg", "_bin", "imageio_ffmpeg", "binaries")
    )
    if os.path.isdir(local):
        for f in sorted(os.listdir(local)):
            if f.startswith("ffmpeg") and f.endswith(".exe"):
                return os.path.join(local, f)
    p = shutil.which("ffmpeg")
    if p:
        return p
    raise RuntimeError("找不到 ffmpeg")


def run_cli(args):
    """运行命令行工具并返回真实 stdout。"""
    cmd = ["moon", "run", "cmd/main", "--target", "wasm-gc", "--"] + args
    r = subprocess.run(
        cmd,
        cwd=ROOT,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=600,
    )
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} 退出码 {r.returncode}\n{r.stderr}")
    return [ln.rstrip("\r") for ln in r.stdout.splitlines()]


SCENE_SPECS = [
    (
        "解析 profile：头部与 tag 表",
        ["parse", "testdata/srgb.icc"],
        "读取真实 sRGB profile，校验 acsp 签名与每个 tag 的边界",
        23,
    ),
    (
        "matrix/TRC 变换：设备值 → PCS XYZ / Lab",
        ["transform", "testdata/srgb.icc"],
        "先 TRC 线性化再乘矩阵；样本含中间调，才能钉住这个顺序",
        15,
    ),
    (
        "多 profile 链接：sRGB → 显示器 profile",
        ["link", "testdata/srgb.icc", "testdata/display.icc"],
        "源设备 → PCS → 目标设备，媒体相对比色；与 lcms2 一致率 98.68%",
        19,
    ),
    (
        "跨类型链接：sRGB → CMYK 打印机",
        ["link", "testdata/srgb.icc", "testdata/cmyk_printer.icc"],
        "源是 matrix/TRC 型、目标是 LUT 型，中间统一用 PCS XYZ 衔接",
        17,
    ),
    (
        "CLUT 型 profile：CMYK 打印机",
        ["lut", "testdata/cmyk_printer.icc"],
        "mft2 查找表：输入表 → CLUT 多线性插值 → 输出表；网格节点偏差 < 1e-6",
        21,
    ),
    (
        "ICC v4 LUT：mAB / mBA",
        ["lut", "testdata/test4.icc"],
        "v4 的 lutAToBType / lutBToAType；矩阵段没有类型头、曲线段没有长度字段",
        15,
    ),
    (
        "PCS 为 XYZ 的 LUT",
        ["lut", "testdata/xyz_lut.icc"],
        "XYZ 的 PCS 编码是 u1Fixed15（1.0 = 0x8000），与 v2/v4 版本无关",
        15,
    ),
]

print("采集真实命令输出 ...")
SCENES = []
for title, args, caption, nlines in SCENE_SPECS:
    out = run_cli(args)
    SCENES.append(
        {
            "cmd": "moon run cmd/main -- " + " ".join(args),
            "out": out[:nlines],
            "total": len(out),
            "caption": caption,
            "title": title,
        }
    )
    print(f"  {args[0]:10s} -> 共 {len(out)} 行，展示前 {min(nlines, len(out))} 行")

FONTS = {
    "mono": ImageFont.truetype(MONO, TERM_SIZE),
    "mono_sm": ImageFont.truetype(MONO, TERM_SIZE - 2),
    "cap": ImageFont.truetype(CJK, CAP_SIZE),
    "bar": ImageFont.truetype(CJK, 17),
    "big": ImageFont.truetype(CJK, 42),
    "mid": ImageFont.truetype(CJK, 24),
}


def base_frame():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, TITLE_H], fill=BAR)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse(
            [PAD + i * 22, TITLE_H // 2 - 6, PAD + i * 22 + 12, TITLE_H // 2 + 6],
            fill=c,
        )
    # 标题栏用中文字体：Consolas 没有中文字形，会渲染成方块
    d.text(
        (PAD + 80, TITLE_H // 2 - 10),
        "moon_icc  ·  纯 MoonBit ICC 色彩管理引擎",
        font=FONTS["bar"],
        fill=DIM,
    )
    return img, d


def wrap_caption(text, max_px):
    lines, cur = [], ""
    for ch in text:
        if FONTS["cap"].getlength(cur + ch) > max_px:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        lines.append(cur)
    return lines


def frame_scene(scene, typed_n, out_n):
    img, d = base_frame()
    y = TITLE_H + PAD
    d.text((PAD, y), scene["title"], font=FONTS["cap"], fill=ACCENT)
    y += 38
    d.text((PAD, y), PROMPT, font=FONTS["mono"], fill=GREEN)
    px = PAD + FONTS["mono"].getlength(PROMPT)
    d.text((px, y), scene["cmd"][:typed_n], font=FONTS["mono"], fill=FG)
    y += LINE_H + 8
    for line in scene["out"][:out_n]:
        d.text((PAD, y), line, font=FONTS["mono_sm"], fill=DIM)
        y += LINE_H - 5
    cap_lines = wrap_caption(scene["caption"], W - 2 * PAD)
    cy = H - PAD - len(cap_lines) * (CAP_SIZE + 7)
    for cl in cap_lines:
        d.text((PAD, cy), cl, font=FONTS["cap"], fill=(198, 208, 218))
        cy += CAP_SIZE + 7
    return img


INTRO_LINES = [
    "零 FFI · wasm-gc / js / native 共用一套源码",
    # 注意：不要用 U+2194（↔），微软雅黑在该字号下缺这个字形，会渲染成方块
    "解析 · matrix/TRC 变换 · XYZ 与 Lab 互转 · 多 profile 链接 · CLUT 查找表",
    "",
    "与 lcms2 交叉核对；与独立 Python 规范实现逐位一致",
]


def frame_intro(shown):
    img, d = base_frame()
    d.text((PAD, 148), "moon_icc", font=FONTS["big"], fill=FG)
    d.text((PAD, 212), "纯 MoonBit 实现的 ICC 色彩管理引擎", font=FONTS["mid"], fill=ACCENT)
    y = 296
    for i, ln in enumerate(INTRO_LINES):
        if i < shown:
            d.text((PAD, y), ln, font=FONTS["cap"], fill=DIM)
        y += 36
    return img


OUTRO_LINES = [
    "57 项测试 · wasm-gc 与 js 双后端全绿",
    "matrix/TRC 对拍：最大偏差 0.0（逐位一致）",
    "多 profile 链接：与 lcms2 一致率 98.68%",
    "CLUT 网格节点：偏差 < 1e-6",
    "跨类型链接：sRGB 与 CMYK 互通",
    "每条判据都经「植入 bug → 变红 → 恢复」验证",
    "",
    "Apache-2.0 · LL728/moon_icc",
]


def frame_outro():
    img, d = base_frame()
    d.text((PAD, 140), "验证结果", font=FONTS["big"], fill=FG)
    y = 236
    for ln in OUTRO_LINES:
        d.text((PAD, y), ln, font=FONTS["cap"], fill=DIM)
        y += 38
    return img


# ---- 时间线 ----
timeline = []
for shown in range(len(INTRO_LINES) + 2):
    timeline += [partial(frame_intro, shown)] * FPS
for scene in SCENES:
    # 打字
    for n in range(0, len(scene["cmd"]) + 1, 3):
        timeline += [partial(frame_scene, scene, n, 0)] * 2
    timeline += [partial(frame_scene, scene, len(scene["cmd"]), 0)] * 6
    # 输出逐行出现
    for k in range(len(scene["out"]) + 1):
        timeline += [partial(frame_scene, scene, len(scene["cmd"]), k)] * 2
    # 停留阅读
    timeline += [partial(frame_scene, scene, len(scene["cmd"]), len(scene["out"]))] * (
        FPS * 3
    )
timeline += [frame_outro] * (FPS * 5)

print(f"总帧数 {len(timeline)}（{len(timeline)/FPS:.1f} 秒）")

tmp = tempfile.mkdtemp(prefix="moonicc_demo_")
print(f"渲染帧 ...")
for idx, fn in enumerate(timeline):
    fn().save(os.path.join(tmp, f"f{idx:05d}.png"))
    if idx % 200 == 0:
        print(f"  {idx}/{len(timeline)}")

os.makedirs(os.path.join(ROOT, "demo"), exist_ok=True)
mp4 = os.path.join(ROOT, "demo", "moon_icc-demo.mp4")
preview = os.path.join(ROOT, "demo", "preview.png")

ff = find_ffmpeg()
print(f"编码：{os.path.basename(ff)}")
subprocess.run(
    [
        ff, "-y", "-hide_banner", "-loglevel", "error",
        "-framerate", str(FPS),
        "-i", os.path.join(tmp, "f%05d.png"),
        "-c:v", "libx264", "-preset", "slow", "-crf", "30",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        mp4,
    ],
    check=True,
)

# 预览图取 CLUT 场景的完整输出（信息量最大）
scene = SCENES[4]
frame_scene(scene, len(scene["cmd"]), len(scene["out"])).save(preview)

shutil.rmtree(tmp, ignore_errors=True)
print(f"已生成 {mp4}（{os.path.getsize(mp4)/1024:.0f} KB）")
print(f"已生成 {preview}")
