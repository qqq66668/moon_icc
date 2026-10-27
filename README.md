# moon_icc

纯 MoonBit 实现的 **ICC 色彩管理引擎**：解析 ICC profile 并执行真实色空间变换，不依赖任何 C 库或系统色彩管理系统。

[![CI](https://github.com/qqq66668/moon_icc/actions/workflows/ci.yml/badge.svg)](https://github.com/qqq66668/moon_icc/actions/workflows/ci.yml)

![演示预览](demo/preview.png)

▶ **[演示视频（60 秒，1280×720）](demo/moon_icc-demo.mp4)** —
七个场景依次运行 `parse` / `transform` / `link` / `lut` 子命令，
覆盖 matrix/TRC 变换、跨类型链接、v2 的 `mft2`、v4 的 `mAB`/`mBA`、
以及 PCS 为 `XYZ ` 的 LUT。视频里的每一行都是当场跑出来的，不是摆拍；
可用 `python tools/make_demo_video.py` 重新生成。

## 这个库解决什么问题

MoonBit 生态里已有图像处理与渲染栈（图像编解码、2D 光栅化、PDF 读写、排版引擎），但**没有色彩管理**：它们可以解出像素、画出图形、排出页面，却无法回答一个基础问题——**这些 RGB 数值在目标设备上到底是什么颜色**。

具体缺口：

| 已有 | 缺什么 |
|---|---|
| 色彩空间数值转换（sRGB↔HSL↔XYZ） | 按 ICC profile 做**设备相关**变换 |
| 能解析 ICC profile 元数据的库 | 用 profile 做**实际色变换** |
| 图像编解码 | 图像进入/离开色彩工作流时的**色彩管理环节** |

`moon_icc` 补的是中间那一层：**读取 ICC profile，并真的按它做变换**——
从单个 profile 的色空间变换（设备编码值 ↔ PCS XYZ ↔ Lab），
到源设备到目标设备的完整色彩管理链路。

## 安装

```
moon add qqq66668/moon_icc
```

在 `moon.pkg` 中导入：

```
import {
  "qqq66668/moon_icc",
}
```

## 用法

### 解析 ICC profile

```moonbit
let data = @fs.read_file_to_bytes("sRGB Color Space Profile.icc")
let header = @moon_icc.parse_header(data)
println(header.device_class)   // "mntr"
println(header.color_space)    // "RGB "
println(header.pcs)            // "XYZ "
println(header.date_time.to_iso_string())  // "1998-02-09T06:49:00"

let tags = @moon_icc.parse_tag_table(data, header)
for tag in tags {
  println("\{tag.signature} 偏移=\{tag.offset} 长度=\{tag.size}")
}
```

### 变换到 PCS（XYZ / Lab）

```moonbit
let data = @fs.read_file_to_bytes("sRGB Color Space Profile.icc")
let profile = @moon_icc.Profile::parse(data)
let transform = profile.matrix_trc()

// sRGB 中灰 (0.5, 0.5, 0.5) → PCS XYZ
let xyz = transform.to_pcs(0.5, 0.5, 0.5)
// xyz = (0.20640003241890215, 0.21403939749252843, 0.17660683523992873)

// 再转到 Lab
let lab = @moon_icc.xyz_to_lab(xyz)
println(lab.l)  // 53.585...
```

### 源 profile → 目标 profile（多 profile 链接）

```moonbit
let src = @moon_icc.Profile::parse(@fs.read_file_to_bytes("sRGB Color Space Profile.icc"))
let dst = @moon_icc.Profile::parse(@fs.read_file_to_bytes("display.icc"))

// 媒体相对比色意图
let link = @moon_icc.ColorTransform::new(src, dst)
let (r, g, b) = link.transform(0.5, 0.5, 0.5)
```

### 跨类型链接（matrix/TRC ↔ LUT）

两侧各自可以是 matrix/TRC 型或 LUT 型，四种组合都支持——中间统一用
PCS XYZ 衔接。因此 **sRGB → CMYK 打印机**这样的跨类型链接可用：

```moonbit
let rgb = @moon_icc.Profile::parse(@fs.read_file_to_bytes("sRGB Color Space Profile.icc"))
let cmyk = @moon_icc.Profile::parse(@fs.read_file_to_bytes("printer.icc"))
let link = @moon_icc.ColorTransform::new(rgb, cmyk)

// 源 3 通道 → 目标 4 通道，用通道数无关的 transform_values
let out = link.transform_values([ 0.5, 0.5, 0.5 ])   // 4 个 CMYK 分量
```

`source_channels()` / `destination_channels()` 给出两侧的通道数，
由 profile 的色空间决定（RGB 为 3、CMYK 为 4）。

命令行等价形式：

```
moon run cmd/main --target wasm-gc -- link testdata/srgb.icc testdata/display.icc
moon run cmd/main --target wasm-gc -- link testdata/srgb.icc testdata/cmyk_printer.icc
```

输出首两行是两侧通道数，随后是 0..255 的灰阶映射（量化到 8 位），
每行 `link <输入> <输出通道...>`，可直接与 lcms2 之类的参考实现比对：

```
src_channels 3
dst_channels 3
link 0 0 0 0
link 1 9 9 9
...
```

CMYK 目标时输出 4 个分量：

```
src_channels 3
dst_channels 4
link 0 0 0 0 255
link 1 1 2 1 255
...
```

### 软打样（soft proofing）

在一台显示器上预看「这张图印在目标设备上会是什么样」。链路是

```text
源设备值 → PCS → 打样设备值 → PCS → 显示设备值
             A2B    B2A         A2B    B2A
```

中间那次往返是关键：它把超出打样设备色域的颜色按该设备的实际能力裁掉。

```moonbit
let chain = @moon_icc.ColorTransform::proofing(
  @moon_icc.Profile::parse(@fs.read_file_to_bytes("sRGB Color Space Profile.icc")),
  @moon_icc.Profile::parse(@fs.read_file_to_bytes("printer.icc")),   // 打样：CMYK 印刷机
  @moon_icc.Profile::parse(@fs.read_file_to_bytes("display.icc")),   // 显示设备
  1,   // 源/显示侧意图：媒体相对比色
  1,   // 打样意图：也可用 3（绝对比色）
)
let (proof_values, shown) = chain.evaluate([ 0.5, 0.5, 0.5 ])
// proof_values = 印这张图会用到的 CMYK 四个分量
// shown        = 屏幕上应显示的 RGB
```

命令行：

```
moon run cmd/main --target wasm-gc -- proof testdata/srgb.icc testdata/cmyk_printer.icc testdata/display.icc
```

输出每行 `proof <灰阶> | <打样设备值> | <显示设备值>`：

```
proof_intent 1
proof_channels 4
display_channels 3
proof 0 | 0 0 0 255 | 41 41 40
proof 51 | 13 17 16 224 | 61 60 59
```

打样链与 lcms2 的 `cmsCreateProofingTransform` 交叉核对通过：
相对/相对 7/16 完全一致、相对/绝对打样 9/16，**两者最大偏差均为 1 级**
（金标生成器见 `tools/gen_proof_golden.py`）。

### 色域判断（gamut check）

判据是**几何色域边界**：只用「设备值产生的颜色」（按定义全在色域内）建边界，
再判查询颜色是否落在边界内。

```moonbit
let source = @moon_icc.Profile::parse(@fs.read_file_to_bytes("sRGB Color Space Profile.icc"))
let target = @moon_icc.Profile::parse(@fs.read_file_to_bytes("printer.icc"))

// 建边界：CMYK 用 9 层采样 = 6561 个设备值 → A2B → Lab
let boundary = target.gamut_boundary(1, 9)
println(boundary.samples())    // 6561
println(boundary.coverage())   // 0.83...（CMYK 色域不填满 Lab 的所有方向）

// 判一个颜色（sRGB 纯绿）
let lab = @moon_icc.xyz_to_lab(source.device_to_pcs(1, [ 0.0, 1.0, 0.0 ]))
println(boundary.contains(lab))          // false —— SWOP CMYK 覆盖不了
println(boundary.signed_distance(lab))   // 18.70...（越界了多少，Lab 单位）
```

**为什么不用「往返 ΔE」判定**（本项目第一版的做法，已被证伪）：

往返误差里混着**颜色映射误差**——同一个 profile 的 A2B 与 B2A 是两张独立的表，
CMYK 还受 GCR 与总墨量限制，二者并不严格互逆。实测 1296 个 CMYK 设备值样本
（按定义**全部在色域内**）：往返误差平均 6.78 ΔE、最大 19.73，用当时的自适应
容差 5.59 判定会误判 **696/1296 = 53.7%**。改用几何边界后，同一类样本
（边界 9 层、验证 7 层共 2401 个）误判 **0**。

两者是不同的量，不要混用：

| 指标 | 含义 | 用途 |
|---|---|---|
| `GamutBoundary::contains` / `signed_distance` | 到设备色域边界的几何位置 | **色域判定** |
| `Profile::round_trip_delta_e` | A2B 与 B2A 的互逆程度 | 设备特性/打样质量的**映射误差**指标 |

命令行（第 4 个参数是边界采样层数，默认 9）：

```
moon run cmd/main --target wasm-gc -- gamut testdata/srgb.icc testdata/cmyk_printer.icc
```

```
sectors 16
samples 6561
coverage 0.94140625
gamut 0 0 0 0 boundary=out dist=8.59 mapping_de=12.88     ← 纸到不了 L*=0
gamut 1 255 255 255 boundary=out dist=5.69 mapping_de=3.42   ← 超出纸白边界
gamut 3 0 255 0 boundary=out dist=18.70 mapping_de=55.83  ← SWOP 覆盖不了 sRGB 纯绿
```

注意 `boundary` 与 `mapping_de` 刻意并列输出：前者是几何判定，后者是映射误差。
两者的结论可以相反——中性灰 34（`gamut 10`）映射误差 3.47 却**在色域内**（距边界 5.70），
而 sRGB 纯白映射误差只有 3.42 却**超出**纸白边界 5.69。判据有效性的证据见
[MUTATION.md](MUTATION.md)。

### 命令行示例

仓库自带一个可运行的示例程序：

```
moon run cmd/main --target wasm-gc -- parse testdata/srgb.icc
moon run cmd/main --target wasm-gc -- transform testdata/srgb.icc
moon run cmd/main --target wasm-gc -- link testdata/srgb.icc testdata/display.icc
moon run cmd/main --target wasm-gc -- link testdata/srgb.icc testdata/cmyk_printer.icc
moon run cmd/main --target wasm-gc -- link testdata/srgb.icc testdata/cmyk_printer.icc saturation
moon run cmd/main --target wasm-gc -- link testdata/srgb.icc testdata/cmyk_printer.icc absolute
moon run cmd/main --target wasm-gc -- proof testdata/srgb.icc testdata/cmyk_printer.icc testdata/display.icc
moon run cmd/main --target wasm-gc -- gamut testdata/srgb.icc testdata/cmyk_printer.icc
moon run cmd/main --target wasm-gc -- lut testdata/cmyk_printer.icc
moon run cmd/main --target wasm-gc -- lut testdata/test4.icc
```

`parse` 输出 profile 的头部与 tag 表：

```
size 3144
version 2.1
class mntr
colorspace RGB 
pcs XYZ 
datetime 1998-02-09T06:49:00
intent 0
illuminant 0.964202880859375 1 0.8249053955078125
tagcount 17
cprt 336 51
desc 388 108
wtpt 496 20
...
```

`transform` 输出固定样本点的变换结果（含中间调，便于对拍）：

```
sample 0.25 0.049063689759460294 0.050879655743278275 0.041981500061132944 ...
sample 0.5 0.20640003241890215 0.21403939749252843 0.17660683523992873 ...
sample 1 0.9642791748046875 0.999969482421875 0.8250885009765625 ...
```

## 当前进度

| 功能 | 状态 |
|---|---|
| ICC profile 二进制解析（头部 + tag 表，含边界校验） | ✅ 已完成并验证 |
| tag 数据解析（`XYZ ` / `curv` / `para`） | ✅ 已完成并验证 |
| matrix/TRC 类型 profile → PCS XYZ 变换 | ✅ 已完成并验证 |
| XYZ ↔ Lab 转换与 CIE76 色差 | ✅ 已完成并验证 |
| 逆变换（PCS XYZ → 设备 RGB）与矩阵求逆 | ✅ 已完成并验证 |
| 多 profile 链接（源设备 → PCS → 目标设备） | ✅ 已完成并验证 |
| 媒体相对比色意图 | ✅ 已完成并验证 |
| CLUT 型 profile 变换（`mft1` / `mft2`，CMYK 打印机等） | ✅ 已完成并验证 |
| 跨类型链接（matrix/TRC ↔ LUT 任意组合） | ✅ 已完成并验证 |
| 渲染意图：感知 / 媒体相对比色 / 饱和度 | ✅ 已完成并验证 |
| 渲染意图：绝对比色（PCS 白点缩放） | ✅ 已完成并验证（对 lcms2 197/200 完全一致、最大 1 级） |
| `mAB` / `mBA`（ICC v4 LUT） | ✅ 已完成并验证 |
| PCS 为 `XYZ ` 的 LUT 型 profile | ✅ 已完成并验证（v4 样本；v2 路径无样本，见「不作为目标」的诚实清单） |
| 软打样链（源 → 打样设备往返 → 显示器） | ✅ 已完成并验证（对 lcms2 proofing 最大偏差 1 级） |
| 色域判断（几何色域边界：球面直方图） | ✅ 已完成并验证（设备值样本 0 误判；被证伪的往返 ΔE 法在同类样本上误判 53.7%） |

## CLUT 型 profile 变换

大量真实世界的 profile（印刷、CMYK、扫描仪）不是矩阵/TRC 型，而是把整个
变换存在一张多维查找表里。本库支持 ICC v2 的两种 LUT 类型：

| 类型 | 名称 | 表值位深 |
|---|---|---|
| `mft1` | lut8Type | 8 位（表固定 256 项） |
| `mft2` | lut16Type | 16 位（表项数在文件里显式给出） |

处理顺序：**输入表 → 矩阵（仅 3 输入通道时）→ CLUT（多线性插值）→ 输出表**。

用法：

```moonbit
let profile = @moon_icc.Profile::parse(@fs.read_file_to_bytes("printer.icc"))
// 设备值按 profile 输入色空间的通道顺序给出，0..1
let lab = profile.device_to_lab(1, [ 0.0, 0.0, 0.0, 0.5 ])  // CMYK 50% 黑
```

命令行：

```
moon run cmd/main --target wasm-gc -- lut testdata/cmyk_printer.icc
```

### 实现中容易错的三处

**（一）`mft2` 的字段顺序：矩阵在前，表项数在后。**

矩阵在偏移 `12..47`（9 × s15Fixed16），输入/输出表项数在 `48..51`，
表数据从 `52` 开始。本项目最初按"表项数在 12..15、矩阵在 16..51"实现，
结果与该 tag 的声明长度差 2052 字节；改用正确顺序后
`52 + 4×256×2 + 9⁴×3×2 + 3×2×2 = 41478`，与声明长度**精确相等**，
且 12..47 处读到标准单位矩阵、48..51 处读到 256 与 2。

**（二）ICC v2 的 Lab 编码上限是 `0xFF00`，不是 `0xFFFF`。**

| 版本 | 位深 | L 满量程 | a/b 满量程 |
|---|---|---|---|
| v2 | 16 | `0xFF00` = 65280 | `0xFF00` |
| v2 | 8 | `0xFF` = 255 | `0xFF` |
| v4 | 16 | `0xFFFF` = 65535 | `0xFFFF` |

因此解码要同时知道位深与版本。另有一个陷阱：**不能在折算之后把结果夹到
1.0**——v2 的 profile 会合法地存到 `0xFFFF`（表示略高于 100 的 L）。
本项目最初正是这样写的，网格节点判据立刻抓到：期望 100.387561，实得 100。

**（三）意图到 tag 的映射：`A2B0`/`A2B1`/`A2B2` 是三个不同的表。**

| 意图 | 编号 | 设备→PCS | PCS→设备 |
|---|---|---|---|
| 感知 | 0 | `A2B0` | `B2A0` |
| 媒体相对比色 | 1 | `A2B1` | `B2A1` |
| 饱和度 | 2 | `A2B2` | `B2A2` |

本机 CMYK profile 的 A2B0 与 A2B1 逐字节比较有 **26539 处差异**，全在 CLUT 区。
若把相对比色误接到 A2B0，暗端会差约 5 个 L 单位。

**（四）输入表常常不是恒等，不能假定"节点索引/网格数"就落在节点上。**

实测该 profile 通道 0 在 v=0.75 处表值为 49151，而恒等应为 49344。
因此网格节点判据的输入必须**反解输入表**得到（见
`tools/gen_clut_golden.py`），否则测到的是节点之间的插值结果，
节点判据就失效了。

## ICC v4 的 LUT（`mAB ` / `mBA `）

ICC v4 把 LUT 换成了两种新类型，分段更灵活：

| 类型 | 名称 | 方向 |
|---|---|---|
| `mAB ` | lutAToBType | 设备 → PCS |
| `mBA ` | lutBToAType | PCS → 设备 |

每一段都可以缺省（偏移为 0），处理顺序由方向决定：

```
mAB：A 曲线 → CLUT → M 曲线 → 矩阵 → B 曲线
mBA：B 曲线 → 矩阵 → M 曲线 → CLUT → A 曲线
```

两处与 `mft1`/`mft2` 差别很大、**照直觉写就会错**的地方：

**（一）矩阵段没有类型签名头。** 偏移直接指向 9 个 `s15Fixed16`
矩阵项，紧跟 3 个 `s15Fixed16` 偏移项，共 48 字节。
而曲线段**是有**类型签名的——两者不一致。本项目初期按"先跳 8 字节类型头"
读矩阵，结果把 M 段的 `para` 签名当成了矩阵偏移项（读出的"偏移"约
28769.44，正是 `'para'` 四个字节被当成定点数的结果），与参考实现的最大偏差
达到 10 级。

**（二）内嵌曲线段没有长度字段。** 类型签名之后的 4 字节是**保留位**，
不是长度；段长只能按类型从内容推算，再补齐到 4 字节边界：

| 类型 | 内容 | 长度 |
|---|---|---|
| `curv` 项数 0 | 恒等 | 8 + 4 |
| `curv` 项数 1 | 单个 gamma | 8 + 4 + 2 |
| `curv` 项数 n>1 | 查找表 | 8 + 4 + 2n |
| `para` | 函数类型 + 参数 | 8 + 4 + 4×(1/3/4/5/7) |

对拍样本的曲线段保留位恰好全为 0；若当成长度读，会原地打转或读错位。

**（三）两个方向的插值方式不同。** 参考实现的 3 输入 CLUT 默认用
**四面体**插值，但在 `PCS` 为 `Lab ` 的**输出** LUT 上会改回**三线性**
（lcms2 `cmsio1.c` 的 `_cmsReadOutputLUT`，源码注释称此处为
"controversial stuff"）。本库照此实现，并用实测确认了它是对的：

| 插值选择 | 与 lcms2 的一致率（40 样本） |
|---|---|
| `mAB ` 四面体 + `mBA ` 三线性（本库） | 见下表 |
| 两者对调 | 2 项测试变红，A2B0 差 3 级、B2A0 差 4 级 |

**（四）逐级夹紧。** 参考实现的 16 位定点管线在每一级之后把值限制在
`[0, 65535]`。`mBA` 的 M 曲线在超色域输入下会算出负值，不夹紧会与参考实现
差出数十级。

### 实测（`testdata/test4.icc`，40 个样本，8 位域）

| tag | 方向 | 完全一致 | 差 1 级 | 最大偏差 |
|---|---|---|---|---|
| `A2B0` | 设备 → PCS | **40/40** | 0 | **0 级** |
| `A2B1` | 设备 → PCS | **40/40** | 0 | **0 级** |
| `B2A0` | PCS → 设备 | 38/40 | 2 | 1 级 |
| `B2A1` | PCS → 设备 | 39/40 | 1 | 1 级 |

两张 A2B 表**逐位一致**：金标取 lcms2 的 `NOOPTIMIZE` 精确路径
（默认路径会把管线重采样成近似 CLUT，在合成 XYZ 样本上实测会让 b 通道差 4 级）。

判据还包含一层**不依赖插值**的节点检查：`A2B0` 的曲线与矩阵全为恒等，
因此其输出必须精确等于 CLUT 节点值；节点值由测试**直接读原始字节**得到
（用独立分析得出的偏移），不经过库的解析代码。

### 关于 B2A 的对拍口径

PCS → 设备方向**不能**用 `LAB` 模式输入直接对拍：实测参考实现的 8 位 Lab
输入格式器会给送进 CLUT 的坐标加一个偏移（用一个"CLUT 恒等、曲线恒等"的
探针 profile 反解坐标，`L8=1` 时坐标是 0.0353 而非 0.0039，即近黑处抬高约
8/255）。因此金标改用 **`RGB → RGB` 组合变换**（内部先 A2B 再 B2A），
避开该格式器，否则会把参考实现的行为记成本库的误差。

## PCS 为 `XYZ ` 的 LUT 型 profile

LUT 型 profile 的 PCS 既可以是 `Lab `，也可以是 `XYZ `。两者的**编码不同**：

| PCS | 编码 | 1.0 对应 | 上限 |
|---|---|---|---|
| `Lab `（v2） | 16 位线性 | — | `0xFF00`（L=100） |
| `Lab `（v4） | 16 位线性 | — | `0xFFFF`（L=100） |
| `XYZ `（v2 与 v4 相同） | **u1Fixed15Number** | **`0x8000`** | `0xFFFF` = 1.99997 |

即 XYZ 的 PCS 值是 `原始值 / 32768`（8 位表值是 `原始值 / 128`），
**与 profile 版本无关**——这一点与 Lab 恰好相反，也是实现时最容易搞错的地方。
若误按满量程 `0xFFFF` 解释，所有颜色坐标会整体缩小一半。

本库把两个方向统一到 PCS XYZ 作为中间表示：A2B 输出按上表解码，
B2A 输入按上表编码，因此 `Lab ` 与 `XYZ ` PCS 的 profile 可以互相链接。

### 样本是合成的

本机（Windows 驱动目录）与参考实现的测试套件里，带 LUT 的 profile **全是 `Lab ` PCS**，
因此 `XYZ ` PCS 没有现成样本可建立判据。仓库里的 `testdata/xyz_lut.icc` 由
`tools/gen_xyz_lut_profile.py` 合成：设备白点映射到 PCS 白点 D50，
`A2B0`/`B2A0` 都是恒等曲线 + 2×2×2 线性 CLUT，且**能被参考实现读取与变换**
（生成脚本会当场用 lcms2 复核）。线性斜坡让期望值有闭式解：

```
A2B0：XYZ = 设备值 × D50
B2A0：设备值 = XYZ / 1.99997…
组合：设备输出 = 设备输入 × D50 / 1.99997…
```

实测（8 位域，26 个样本）：

| 方向 | 与 lcms2 完全一致 | 最大偏差 | 与解析期望的最大偏差 |
|---|---|---|---|
| 设备 → PCS Lab | **26/26** | **0 级** | — |
| 组合（设备 → PCS → 设备） | **26/26** | **0 级** | 1 级（量化） |

另外测试直接读文件的 CLUT 原始值，要求解码结果恰为 `原始值/32768`——
这条判据不依赖插值，只看编码常数。

## 与 lcms2 的交叉核对（重要）

端到端链接结果与 **lcms2**（业界标准 CMM，经 Pillow 的 `ImageCms` 调用）
用 4096 个随机彩色样本交叉核对。判据是三条，均可证伪：

1. 完全一致率 **≥ 98%**（实测 **98.68%**）；
2. 最大偏差 **≤ 3 级**（8 位量化）；
3. **偏差 ≥2 级的通道，其 lcms2 输出必须 ≤ 8**——把成因钉在极暗区。

为什么不是零容差？追查后的结论是**差异来自 lcms2 一侧的两个已知特性**：

**（一）lcms2 默认走 CLUT 近似。** 它链接两个 profile 时会构建 3D CLUT
并插值（速度优先）。同一批样本实测：

| lcms2 flags | 与本库完全一致 | 最大偏差 |
|---|---|---|
| NONE（默认） | 3942/4096 | 4 级 |
| **NOOPTIMIZE** | **4042/4096** | 3 级 |
| FORCE_CLUT | 3370/4096 | **11 级** |

强制走 CLUT 会让一致率与最大偏差同时显著恶化——这直接证明默认路径的差异
来自 lcms2 自身的近似。金标因此取 `NOOPTIMIZE` 这条精确通路。

**（二）8 位量化边界与 16 位流水线分辨率。** lcms2 在 16 位域上传递中间值。
实测偏差分布：

| 偏差 | 例数 | 目标线性值范围 | lcms2 输出 |
|---|---|---|---|
| 1 级 | 39 | 1.9e-4 .. 9.5e-1（全范围） | 7 .. 248 |
| 2 级 | 9 | 6.7e-5 .. 1.8e-4（极暗） | 2 .. 6 |
| 3 级 | 6 | 8.7e-5 .. 1.2e-4（极暗） | 3 .. 4 |

即：±1 级是全范围的量化边界翻转；**≥2 级只出现在极暗区**——那里目标线性值
仅约 1e-4，在 16 位域只有 6~8 个量化级，lcms2 的输出本身就有数级不确定度，
而本库全程双精度。

**独立证据的另一条腿**：本库与"按 ICC 规范逐字转写的独立双精度实现"
（`tools/diff_oracle.py`）在全部样本上**逐位一致**，因此上面是交叉核对，
本库的正确性不单独依赖 lcms2。

复现全部数字：

```
python tools/gen_golden.py             # 生成链接金标（lcms2 NOOPTIMIZE）
python tools/gen_clut_golden.py        # 生成 CLUT 金标（网格节点 + lcms2）
python tools/gen_cross_link_golden.py  # 生成跨类型链接金标
python tools/gen_intent_golden.py      # 生成四种渲染意图金标
python tools/gen_v4lut_golden.py       # 生成 ICC v4 LUT（mAB/mBA）金标
python tools/gen_xyz_lut_profile.py    # 合成 PCS 为 XYZ 的 LUT profile（并用 lcms2 复核）
python tools/gen_xyz_golden.py         # 生成合成 XYZ profile 的金标
python tools/lcms2_flags_check.py      # 复现 flags 对比表
python tools/lcms2_deviation_report.py # 复现链接偏差分布表
python tools/lcms2_intent_check.py     # 复现"哪些 profile 能区分意图"
python tools/diff_oracle.py wasm-gc    # 独立 Python 规范实现差分
python tools/make_demo_video.py        # 重新生成演示视频
```

## 渲染意图

四种意图经 `ColorTransform::with_intent` 指定，命令行用意图名：

```
moon run cmd/main --target wasm-gc -- link testdata/srgb.icc testdata/cmyk_printer.icc saturation
```

| 编号 | 名称 | 命令行 | 对 LUT 型 profile 的效果 |
|---|---|---|---|
| 0 | 感知 | `perceptual` | 用 `A2B0`/`B2A0` |
| 1 | 媒体相对比色（默认） | `relative` | 用 `A2B1`/`B2A1` |
| 2 | 饱和度 | `saturation` | 用 `A2B2`/`B2A2` |
| 3 | 绝对比色 | `absolute` | 用 `A2B1`/`B2A1`，**外加 PCS 白点缩放** |

非法名称会被拒绝并给出可选值，不静默回退到默认意图。

### matrix/TRC 型 profile 四种意图等价

这类 profile 只有一组矩阵与曲线，没有按意图分开的数据。这不是本库的省略：
实测 lcms2 对 sRGB → 显示器 这组 profile 对，四种意图给出**逐位相同**的结果
（复现：`python tools/lcms2_intent_check.py`）。

### 含多张 LUT 的 profile 意图确实可区分

以本机 CMYK 打印机 profile 为例，以媒体相对比色为基准，感知差 35 级、
饱和度差 255 级、绝对差 20 级。四种意图都与 lcms2 交叉核对，
200 个随机 RGB 样本、8 位域下**最大偏差 ≤ 2 级、一致率 ≥ 60%**。

### 绝对比色的 PCS 白点缩放

绝对比色**不做白点适应**：源的白点在目标上仍按绝对值呈现。在 D50 相对 PCS 上
这等价于在两个阶段之间乘 `diag(源媒体白点 / 目标媒体白点)`。

白点按 lcms2 的 `_cmsReadMediaWhitePoint`（`src/cmsio1.c:64`）取：

- 没有 `wtpt` tag → D50；
- **v2 且设备类为 `mntr`** → D50（老显示器 profile 的 `wtpt` 记的是器件白 D65，
  而它的矩阵列已经适应到 D50。用 D65 会让 Z 分量多乘约 1.32 倍）；
- 其余取 `wtpt` 原值（CMYK 打印机记的是纸张白，显著低于 D50）。

本库第一版正是**在源侧乘了标签里的 D65**，导致与 lcms2 的偏差
从 20 级恶化到 107 级；按上面的取法修正后，200 样本**197/200 完全一致、
最大偏差 1 级**（`intent_wbtest.mbt`）。这条教训同时写进了
`Profile::media_white_point` 的文档。

对 sRGB → CMYK 打印机这组 profile：源侧白点按 D50、目标侧为
(0.8617, 0.8933, 0.7431)，缩放 ≈ (1.119, 1.119, 1.110)。

## 变换顺序与白点（实现要点）

两处最容易错、且**只用端点测试发现不了**的地方：

### 1. TRC 必须先于矩阵

```
linear = TRC(encoded)     # 先线性化
XYZ    = M · linear       # 再乘矩阵
```

顺序颠倒时，白点 `(1,1,1)` 与黑点 `(0,0,0)` **仍然完全正确**——
只有中间调会错。因此测试必须包含中间调样本；
本项目实测：翻转顺序后白点与 D50 的色差达到 **17.3**，中间调用例全部变红。

### 2. PCS 是 D50，但不能自己再做一次色适应

sRGB 的**原生白点是 D65**，而 ICC 的 PCS 固定为 **D50**。
关键在于：sRGB profile 里的 `rXYZ/gXYZ/bXYZ` 矩阵列
**已经**是从 D65 经 Bradford 适应到 D50 的结果。

所以实现**不再做任何色适应**。实测 `(1,1,1)` 经变换得到
`(0.96428, 0.99997, 0.82509)`，与 D50 `(0.9642, 1.0, 0.8249)` 的色差 < 0.1；
若误再加一次适应，白点会明显偏离。

## 不作为目标（明确边界）

本库的终点是「设备↔PCS 数值色彩变换」这条链路（见[当前进度](#当前进度)与
[CONFORMANCE.md](CONFORMANCE.md) 的覆盖矩阵）。下列各项**不属于本项目目标**，
不是"尚未实现的待办"；写在此处以免误用。

- **命名色处理（`nmcl` 类、`ncl2` tag）**：`ncl2` 是"色名 → PCS"的查表，属色彩资产
  管理，不改变任何数值变换行为。本库定位为设备↔PCS 数值色彩变换引擎，不做色名查表。
- **MPE 多处理元素变换（`mped`）**：MPE 是把 curve / matrix / lut 等元素串成链的
  **容器**。本库已实现其全部 constituent 元素的解码与求值（`curv`、`para`、矩阵、
  `mft1`/`mft2`、`mAB`/`mBA`），但不提供任意元素链容器。
- **黑点补偿（BPC）**：非 ICC.1 强制要求，属 CMM 扩展选项；与 lcms2 默认行为一致。
- **感知 / 饱和度意图的色域映射算法**：映射结果由 profile 内 `A2B0`/`A2B2` 承载，
  本库忠实执行 LUT，不自造映射（与 lcms2 同）。
- **iccMAX（ICC.2）**：架构不同（多 PCS、光谱、材质），需要独立设计。
- **色貌模型（CAM）**：超出 ICC PCS 范围；PCS 已隐含观察条件。
- **图像容器读写（PNG / JPEG / TIFF）**：本库只处理色彩数值，不碰图像容器；
  4 通道（CMYK）的求值本身已可用。
- **不完全色适应（`AdaptationState != 1`）**：与 lcms2 默认（`AdaptationState = 1`）
  保持一致；绝对比色只做媒体白点缩放，`chad` 不参与。

### 已实现但判据覆盖不完整（诚实清单）

以下是**已实现**的能力，但缺少真实样本，因此判据强度弱于其他部分：

- **PCS 为 `XYZ ` 的 LUT 型 profile**：v4（`mAB `/`mBA `）已用合成样本
  `testdata/xyz_lut.icc` 验证（26 样本双向对拍 + u1Fixed15 编码常数判据）；
  v2 的 `mft1`/`mft2` + `XYZ ` PCS 走同一段解码代码，但**没有真实样本、未建立判据**。
- **`abst`（PCS→PCS）与 `link`（设备→设备）**：用恒等与解析式合成样本验证
  （生成时经 lcms2 复核可读），但**没有真实世界的该类 profile**。
- **色域判定的外部 oracle**：lcms2 自带的 GDB API 实测不可用
  （`cmsGDBCheckPoint` 对全部查询返回 out），改用独立第二实现
  （lcms2 取 Lab + Python 重写球面直方图）交叉验证，一致率 91.7%；
  **没有与 CMM 内部算法逐位对拍的 oracle**。

PCS 为其他取值（既非 `Lab ` 也非 `XYZ `）时显式报错，不静默给出错误颜色。

## 一致性与标准覆盖

目标规范、设备类覆盖矩阵、各类必需行为、不作为目标清单与已知边界，见
**[CONFORMANCE.md](CONFORMANCE.md)**。可用命令自查：

```
moon run cmd/main --target wasm-gc -- conformance
moon run cmd/main --target wasm-gc -- conformance testdata/cmyk_printer.icc
```

覆盖矩阵只有两种状态：`本次实现`（属于本项目终点，已交付并有判据）与
`不作为目标`（附标准依据）。不使用"暂不覆盖/后续版本"这类含义不明的说法。
证据强度在表内注明：多数设备类用**真实 profile** 验证；`abst`/`link` 因本机没有
该类真实 profile，用**合成样本 + 解析式判据**（生成时经 lcms2 复核可读）。
必需 tag 的检查是可执行的，不是文档里的一句话。

与 mooncakes 上现有色彩包的**对照实验**（同一份 profile、可复现命令）见
**[COMPARISON.md](COMPARISON.md)**。

## 设计要点

### 外部不可信输入

ICC profile 是外部文件，因此解析层不信任任何字段：

- 每一处读取都做边界检查，越界返回结构化错误而不是 panic；
- 头部声明的 `size` 若大于实际字节数会被拒绝（此后所有 tag 偏移都不可信）；
- 每个 tag 的 `offset + size` 必须落在文件范围内；
- tag 条目数必须能装进剩余空间，且乘法做了溢出检查。

错误类型是 `IccError`，含 `Truncated` / `BadSignature` / `SizeMismatch` / `TagOutOfBounds` / `BadTagTable` / `OutOfRange` 六种，均带定位信息。

### 大端序与定点数

ICC 规范（ISO 15076-1 / ICC.1）全程使用**大端序**，且大量使用 16.16 定点数（`s15Fixed16Number`）。定点转换集中在 `reader.mbt`，避免各处重复实现而产生精度偏差。

> 实测教训：用错误的字节序读 `sRGB Color Space Profile.icm`，会把 3144 字节读成 1208745984，且 `acsp` 签名读成乱码。

## 测试与验证

```
moon test --target wasm-gc     # 93 项测试
moon test --target js          # 同一套测试，js 后端
moon test --target native      # 同一套测试，native 后端
python tools/diff_oracle.py wasm-gc    # 外部 oracle 差分
python tools/diff_oracle.py js         # 同上，js 后端
python tools/verify_publish.py         # 在全新工程里实拉已发布包并跑真实变换
python tools/check_readme_examples.py  # 把本文件的示例代码逐块实跑并核对其中公布的数值
python tools/gen_proof_golden.py       # 重新生成软打样金标（需要 MSYS2 gcc 编译 lcms2）
python tools/gen_abst_link_profiles.py # 重新生成 abst / link 合成样本（生成时用 lcms2 复核）
python tools/compare_gamut.py          # 色域边界的独立对拍（lcms2 取 Lab + Python 重写，一致率 91.7%）
# 判据有效性（刻意植入错误看测试是否变红）见 MUTATION.md
moon run cmd/main -- conformance       # 打印设备类覆盖矩阵（标准版本与必需行为）
```

> `check_readme_examples.py` 与 `verify_publish.py` **不放进 CI 的 push 门禁**：
> 它们从 mooncakes.io 拉取**已发布版本**，而 push 门禁跑的是**当前源码**——
> 若改了示例但尚未发布，二者会不一致而产生误报。这两个脚本用于**发布前后**的人工验证。

### 核心功能 → 判据对照

| 核心功能 | 覆盖它的判据 |
|---|---|
| profile 解析（头部 + tag 表 + 边界校验） | `header_wbtest.mbt`（合成字节流，含畸形输入）；`tools/diff_oracle.py` 对 5 个真实 profile 逐字段比对 |
| matrix/TRC 变换与逆变换 | `transform_wbtest.mbt`；`link_golden_wbtest.mbt`（4096 彩色样本对 lcms2）；差分脚本逐位比对 |
| LUT 变换（`mft1`/`mft2`） | `clut_wbtest.mbt`（625 个网格节点 + 300 个 lcms2 CMYK 样本）；`tools/gen_clut_golden.py` 反解输入表定位节点 |
| LUT 变换（`mAB `/`mBA `，v4） | `v4lut_wbtest.mbt`（节点判据读原始字节 + 40 样本对 lcms2）；`tools/diff_oracle.py` 独立结构对拍 |
| PCS 为 `XYZ ` 的 LUT | `xyz_lut_wbtest.mbt`（u1Fixed15 编码常数判据 + 26 样本双向对拍 + 解析期望式） |
| 多 profile 链接（四种跨类型组合） | `cross_link_wbtest.mbt` + `cross_link_golden_wbtest.mbt`（sRGB ↔ CMYK 各 300 样本） |
| 渲染意图（感知 / 相对 / 饱和度 / 绝对） | `intent_wbtest.mbt` + `intent_golden_wbtest.mbt`（200 样本 × 四意图）；绝对比色另断言「与相对比色必须不同」以防缩放失效 |
| 软打样链 | `proofing_wbtest.mbt`（自洽性 + 物理正确性）+ `proof_golden_wbtest.mbt`（lcms2 `cmsCreateProofingTransform` 金标，最大偏差 1 级） |
| 色域判断 | `proofing_wbtest.mbt`（设备值样本零误判、纸白与设备黑 in、PCS 黑与原色 out、覆盖率、映射误差独立性） |
| 抽象 profile（`abst`）与 device link（`link`） | `abstract_link_wbtest.mbt`（恒等抽象不改变 PCS；device link 等于闭式 C=1-R, M=1-G, Y=1-B, K=0）|
| 命令行示例与端到端可用性 | `cmd/main` 四子命令；`tools/verify_publish.py` 在仓库之外的空工程里 `moon add` 实拉并运行 |

判据分四层，独立性递增：

1. **合成字节流**：精确构造每个字段，验证解析逻辑本身（含畸形输入）；
2. **真实 profile**：Windows 系统自带的 3 个真实 profile（matrix/TRC 型 sRGB、
   真实显示器、CMYK/LUT 打印机），外加 Little-CMS 测试套件里的 ICC v4 profile
   `test4.icc`（覆盖 `mAB ` / `mBA `，来源与许可见 `testdata/README.md`）；
3. **外部 oracle**：七个来源——
   - `tools/diff_oracle.py`：Python `struct` **独立**按规范解析并**独立重做** matrix/TRC 变换，与本库逐字段、逐样本比对；并对 v4 的 `mAB `/`mBA ` 做独立结构对拍（网格、精度、各段曲线条数、矩阵项数）；
   - `link_golden_wbtest.mbt`：lcms2 生成的 4096 个彩色样本金标（matrix/TRC → matrix/TRC）；
   - `clut_golden_wbtest.mbt`：625 个 CLUT 网格节点 + 300 个 lcms2 CMYK 样本；
   - `cross_link_golden_wbtest.mbt`：lcms2 生成的跨类型链接金标（sRGB ↔ CMYK 各 300 个随机样本）；
   - `intent_golden_wbtest.mbt`：lcms2 生成的四种渲染意图金标（200 个随机 RGB 样本，四意图共用输入）；
   - `v4lut_golden_wbtest.mbt`：lcms2 生成的 v4 LUT 金标（`A2B0`/`A2B1`/`B2A0`/`B2A1` × 40 样本）；
   - `xyz_lut_golden_wbtest.mbt`：lcms2 生成的合成 XYZ-PCS profile 金标（`RGB→LAB` 与 `RGB→RGB` 各 26 样本）；
   - `proof_golden_wbtest.mbt`：**C 版 lcms2** 生成的软打样金标。Pillow 不暴露 proofing 接口，因此 `tools/gen_proof_golden.py` 用 MSYS2 gcc 编译 `_research` 下的 Little-CMS 源码，调用 `cmsCreateProofingTransform`（`SOFTPROOFING | NOOPTIMIZE`）；
4. **网格节点**：CLUT 节点值不依赖插值细节，任何正确实现在节点上都必须
   返回存储值。这一层单独钉住**解析、索引步长、Lab 解码**；
   `v4lut_wbtest.mbt` 里还有一条同类的 v4 节点判据。

**实测结果**：

- matrix/TRC 差分：3 个 profile × 15 个样本 × 3 个分量，**最大偏差 0.0（逐位一致）**，
  wasm-gc 与 js 双后端相同。容差因此设为 `1e-15`。
- 与 lcms2 交叉核对（matrix/TRC → matrix/TRC）：一致率 98.68%，判据见上文。
- CLUT 网格节点：625 个节点与独立解析的偏差 **< 1e-6**（金标精度上限）。
- CLUT 对 lcms2：**最大偏差恰为 1 级**（8 位），无 2 级及以上；
  L 通道平均有符号差 −0.11 级，即无系统性偏移。
- 跨类型链接对 lcms2（各 300 个随机样本，8 位域）：
  - sRGB → CMYK：完全一致 **297/300（99%）**，最大偏差 ≤ 2 级；
  - CMYK → sRGB：完全一致 173、差 1 级 125、差 2 级 2，最大偏差 2 级。
- 渲染意图对 lcms2（200 个随机样本，8 位域）：感知 / 相对比色 / 饱和度
  三种意图**最大偏差 ≤ 2 级、一致率 ≥ 60%**；**绝对比色 197/200 完全一致、
  最大偏差 1 级**。
- 软打样对 lcms2 `cmsCreateProofingTransform`（16 个灰阶样本，8 位域）：
  相对/相对 7/16 完全一致、相对/绝对打样 9/16，**两者最大偏差均为 1 级**。
- 色域判断（sRGB → CMYK 打印机，几何边界）：
  - 设备值样本（边界 9 层、验证 7 层，2401 个）误判 **0**；
    旧往返 ΔE 法在 1296 个同类样本上误判 **696（53.7%）**，平均映射误差 6.78、最大 19.73；
  - 纸白与「设备能产生的最深黑」判 in；PCS 纯黑（L*=0）与 sRGB 纯绿/纯蓝判 out；
  - 边界采样覆盖率 0.94（9 层采样；CMYK 色域不填满 Lab 的所有方向）；
  - **面向不同设备**：3 通道（显示器）与 4 通道（CMYK）设备都能建边界；同一颜色结论随设备不同
    （sRGB 纯红：显示器界内、CMYK 界外）。采样密度需匹配设备——3 通道要 17³ 样本、
    4 通道要 9⁴ 样本才达到 0 误判（9 层建 3 通道边界时实测 3/343 误判）。
- ICC v4 LUT 对 lcms2（`test4.icc`，40 个样本，8 位域）：`A2B0` 与 `A2B1` 均
  **40/40 完全一致（偏差 0）**，`B2A0` 38/40、`B2A1` 39/40，最大偏差 1 级。
- PCS 为 `XYZ ` 的 LUT（合成 `xyz_lut.icc`，26 个样本，8 位域）：设备→PCS Lab 与
  组合变换均 **26/26 完全一致（偏差 0）**。
- v4 结构差分（`tools/diff_oracle.py`）：Python 独立解析的网格、精度、曲线条数与
  矩阵项数，与库的输出全部吻合（含合成 XYZ profile 的 `A3/M0/B3` 结构）。


**判据验证**（主动植入 bug 确认判据是活的，不是空转）：

| 植入的错误 | 单元测试反应 |
|---|---|
| `renderingIntent` 读取位置错位 | 3 项变红，外部差分 12 处不一致 |
| TRC 与矩阵顺序颠倒 | 5 项变红（白点偏离 D50 达 17.3 色差） |
| 矩阵求逆漏掉转置 | 5 项变红（lcms2 一致率跌到 0%） |
| CLUT 维度步长顺序写反 | **4 项变红**（节点偏差 91 个 L 单位，lcms2 差 93 级） |
| LUT 侧 PCS 不做 Lab↔XYZ 转换 | **2 项变红**（偏差 255 级，即完全错） |
| `mAB`/`mBA` 矩阵段按"8 字节类型头 + 矩阵"读 | **5 项变红**（偏差 215–255 级） |
| 取消曲线段 4 字节对齐 | 1 项变红（合成 tag 判据报出 `..cu` 非法曲线类型） |
| 交换两个方向的插值方式 | 2 项变红（A2B0 差 3 级、B2A0 差 4 级） |
| `mBA` 阶段顺序颠倒（矩阵与 M 曲线互换） | 1 项变红（偏差 255 级） |
| 忽略矩阵的偏移项 | 1 项变红（偏差 255 级） |
| XYZ PCS 解码误按 u1Fixed16（数字 32768→65535） | **3 项变红**（节点判据报出 2 倍偏差，端到端差 61–64 级） |
| XYZ PCS 编码（逆方向）误按 u1Fixed16 | 1 项变红（组合变换差 127 级） |
| 缺省的曲线段返回空数组而非透传 | **3 项变红**（合成 profile 的最大输入处整体输出 0） |

矩阵求逆那条是开发中真实出现过的 bug：逆矩阵写成了转置，与 lcms2 在 8 位域上
最大差 **173/255**。**灰阶样本完全测不出它**（灰阶只走矩阵的对角路径），
是 4096 个**彩色**样本把它抓出来的——这正是金标必须用彩色随机样本的原因。

## 参考与移植说明

本项目为**原创实现**，按 ICC 规范（ISO 15076-1:2005 / ICC.1:2022，即 ICC Profile Format Specification）从零编写，不包含任何第三方代码。

实现过程中参考以下开源项目**理解算法与行为**（仅作对照，未复制代码）：

| 项目 | 语言 | 许可证 | 参考范围 |
|---|---|---|---|
| [Little-CMS (lcms2)](https://github.com/mm2/Little-CMS) | C | MIT | ICC 规范的工程化解读、tag 处理策略 |

> lcms2 采用 MIT 许可证，与本项目 Apache-2.0 兼容。本项目未链接、未编译、未复制其代码；
> 仓库内只包含它的**测试用 profile** `testdata/test4.icc`（用于建立 ICC v4 LUT 判据），
> 其来源、许可与 MIT 声明全文见 [`testdata/README.md`](testdata/README.md)。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
