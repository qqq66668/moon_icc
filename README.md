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

### 命令行示例

仓库自带一个可运行的示例程序，打印 profile 的头部与 tag 表：

```
moon run cmd/main --target wasm-gc -- testdata/srgb.icc
```

输出：

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

## 当前进度

| 功能 | 状态 |
|---|---|
| ICC profile 二进制解析（头部 + tag 表，含边界校验） | ✅ 已完成并验证 |
| matrix/TRC 类型 profile → XYZ 变换 | 计划中 |
| XYZ ↔ Lab 转换与色差 | 计划中 |
| 变换入口 + 外部 oracle 对拍 | 计划中 |

## 明确不做

以下内容**不在**本项目范围内，写在此处以免误用：

- **CLUT 型 profile 变换**（`mft1` / `mft2` / `mAB` / `mBA`）：当前版本能正确**解析**这类 profile，但不对其做变换，会返回明确错误而非静默给出错误结果。
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
moon test --target wasm-gc     # 14 项测试
moon test --target js          # 同一套测试，js 后端
python tools/diff_oracle.py    # 外部 oracle 差分
```

判据分三层，独立性递增：

1. **合成字节流**：精确构造每个字段，验证解析逻辑本身（含畸形输入）；
2. **真实 profile**：用 Windows 系统自带的 3 个真实 profile，覆盖 matrix/TRC 型（sRGB）、真实显示器 profile、CMYK/LUT 型（打印机）；
3. **外部 oracle**：`tools/diff_oracle.py` 用 Python `struct` 模块**独立**按规范解析同一批文件，与本库输出逐字段比对（头部 9 个字段 + 全部 tag 条目）。

第 3 层是关键：被测实现与判据必须来源不同，否则"我又写了一遍"不构成独立证据。

**判据验证**：曾把 `renderingIntent` 的读取位置故意改错，确认单元测试 3 项变红、外部差分报出 12 处不一致——判据是活的，不是空转。

## 参考与移植说明

本项目为**原创实现**，按 ICC 规范（ISO 15076-1:2005 / ICC.1:2022，即 ICC Profile Format Specification）从零编写，不包含任何第三方代码。

实现过程中参考以下开源项目**理解算法与行为**（仅作对照，未复制代码）：

| 项目 | 语言 | 许可证 | 参考范围 |
|---|---|---|---|
| [Little-CMS (lcms2)](https://github.com/mm2/Little-CMS) | C | MIT | ICC 规范的工程化解读、tag 处理策略 |

> lcms2 采用 MIT 许可证，与本项目 Apache-2.0 兼容。本项目未链接、未编译、未复制其代码；如后续引入其任何代码，将按其许可证要求注明。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。
