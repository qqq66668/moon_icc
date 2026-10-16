# moon_icc

纯 MoonBit 实现的 **ICC 色彩管理引擎**：解析 ICC profile 并执行真实色空间变换，不依赖任何 C 库或系统色彩管理系统。

[![CI](https://github.com/LL728/moon_icc/actions/workflows/ci.yml/badge.svg)](https://github.com/LL728/moon_icc/actions/workflows/ci.yml)

## 这个库解决什么问题

MoonBit 生态里已有图像处理与渲染栈（图像编解码、2D 光栅化、PDF 读写、排版引擎），但**没有色彩管理**：它们可以解出像素、画出图形、排出页面，却无法回答一个基础问题——**这些 RGB 数值在目标设备上到底是什么颜色**。

具体缺口：

| 已有 | 缺什么 |
|---|---|
| 色彩空间数值转换（sRGB↔HSL↔XYZ） | 按 ICC profile 做**设备相关**变换 |
| 能解析 ICC profile 元数据的库 | 用 profile 做**实际色变换** |
| 图像编解码 | 图像进入/离开色彩工作流时的**色彩管理环节** |

`moon_icc` 补的是中间那一层：**读取 ICC profile，并真的按它做变换**。

## 安装

```
moon add LL728/moon_icc
```

在 `moon.pkg` 中导入：

```
import {
  "LL728/moon_icc",
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

### 命令行示例

仓库自带一个可运行的示例程序：

```
moon run cmd/main --target wasm-gc -- parse testdata/srgb.icc
moon run cmd/main --target wasm-gc -- transform testdata/srgb.icc
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
| 渲染意图选择（感知 / 相对比色） | 计划中 |
| CLUT 型 profile 变换（CMYK 打印机） | 计划中 |

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

## 明确不做

以下内容**不在**本项目范围内，写在此处以免误用：

- **CLUT 型 profile 变换**（`mft1` / `mft2` / `mAB` / `mBA`）：当前版本能正确**解析**这类 profile，但不对其做变换——调用 `matrix_trc()` 会返回 `BadTagData` 明确报错，而不是静默给出错误颜色（测试覆盖了这条路径：CMYK 打印机 profile 必须显式失败）。
- **渲染意图选择**（感知 / 相对比色 / 饱和度 / 绝对比色）：解析阶段能读出该字段，变换阶段尚未使用。
- **多 profile 链接**（设备→PCS→设备）：不做。
- **CMYK 输出**：依赖 CLUT，不在范围内。
- **图像文件读写**（PNG / JPEG / TIFF）：本库只处理色彩数值，不碰图像容器。
- **软打样、黑点补偿、色貌模型**：不做。

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
moon test --target wasm-gc     # 30 项测试
moon test --target js          # 同一套测试，js 后端
python tools/diff_oracle.py wasm-gc    # 外部 oracle 差分
python tools/diff_oracle.py js         # 同上，js 后端
```

判据分三层，独立性递增：

1. **合成字节流**：精确构造每个字段，验证解析逻辑本身（含畸形输入）；
2. **真实 profile**：用 Windows 系统自带的 3 个真实 profile，覆盖 matrix/TRC 型（sRGB）、真实显示器 profile、CMYK/LUT 型（打印机）；
3. **外部 oracle**：`tools/diff_oracle.py` 用 Python `struct` 模块**独立**按规范解析同一批文件并**独立重做 matrix/TRC 变换**，与本库输出逐字段、逐样本比对。

第 3 层是关键：被测实现与判据必须来源不同，否则"我又写了一遍"不构成独立证据。

**实测结果**：3 个 profile × 15 个变换样本 × 3 个分量，**最大偏差 0.0（逐位一致）**，wasm-gc 与 js 双后端相同。容差因此设为 `1e-15`——参考自身离散度为零，就按紧值设，让结构性错误必然触发失败。

**判据验证**（主动植入 bug 确认判据是活的，不是空转）：

| 植入的错误 | 单元测试反应 | 外部差分反应 |
|---|---|---|
| `renderingIntent` 读取位置错位 | 3 项变红 | 12 处不一致 |
| TRC 与矩阵顺序颠倒 | 5 项变红（含中间调用例，白点偏离 D50 达 17.3 色差） | 变换样本全红 |

## 参考与移植说明

本项目为**原创实现**，按 ICC 规范（ISO 15076-1:2005 / ICC.1:2022，即 ICC Profile Format Specification）从零编写，不包含任何第三方代码。

实现过程中参考以下开源项目**理解算法与行为**（仅作对照，未复制代码）：

| 项目 | 语言 | 许可证 | 参考范围 |
|---|---|---|---|
| [Little-CMS (lcms2)](https://github.com/mm2/Little-CMS) | C | MIT | ICC 规范的工程化解读、tag 处理策略 |

> lcms2 采用 MIT 许可证，与本项目 Apache-2.0 兼容。本项目未链接、未编译、未复制其代码；如后续引入其任何代码，将按其许可证要求注明。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
