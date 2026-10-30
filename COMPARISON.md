# 与现有 MoonBit ICC 包的对照

评审第 1 轮的意见：「现有 MoonBit 引擎已覆盖不少主体变换职责……申请尚未说明这些
净贡献。请……以**具体输入输出案例**说明与现有引擎的关系。」

本文件用可复现的实验回答它。检索口径：2026-10-22 刷新 mooncakes 索引后，
名字或描述与色彩相关的模块共 10 个；其中与 ICC 直接相关的是
`enanandesu/icc`（唯一自带 ICC 字样的包）。其余为数值色彩空间换算
（`bobzhang/colors`、`CAIMEOX/color`、`illusory0x0/color`、
`weedmind-6812/moonbit-color`）、终端着色（`chensuiyi/clicolor`、`zxch3n/colored`），
以及一个内容管理系统（`liuzhiyug/moonbit-multilang-cms`，与色彩无关）和一个
C 编译器（`bobzhang/kimicc`，名字巧合）。

## 实验：把 `enanandesu/icc` 加进一个全新工程

```bash
mkdir icc_compare && cd icc_compare
# moon.mod: name = "verify/icc_compare"
moon add enanandesu/icc          # ← 失败
```

实测输出（moon 0.1.20261012，2026-10-22）：

```
Downloading enanandesu/icc@0.1.1
Error: When installing packages
Caused by:
    `moon.mod.json` at '...\.mooncakes\enanandesu\icc' is no longer supported.
    Run `moon fmt` to migrate to `moon.mod`.
```

它发布的是**旧版包格式**（`moon.mod.json`/`moon.pkg.json`）。按提示手工迁移后，
**源码仍编译不过**——使用的旧语法已被现行编译器移除，例如：

```
error: suberror ParseError String        ← 旧版错误声明语法
error: String 索引返回 UInt16，与 '0'.to_int()（Int）比较类型不符
```

也就是说：**在当前稳定工具链下，这个包无法被任何新工程直接使用**。

## 它的公开 API 能给出什么

从下载到的源码读到的全部公开入口（`icc.mbt`）：

```moonbit
pub fn parse(path : String) -> Map[String, String] raise ParseError
pub fn parse_from_file(path : String) -> Map[String, String] raise ParseError
pub fn parse_from_buffer(...) -> Map[String, String] raise ParseError
pub fn parse_from_bytes(data : Bytes) -> Map[String, String] raise ParseError
pub fn parse_from_string(data : String) -> Map[String, String] raise ParseError
```

**五个入口的返回类型都是 `Map[String, String]`**——即元数据字符串表
（版本、设备类、描述等），没有任何变换入口，也没有数值结果。这与它的自述一致：
README 称其为 "lightweight ICC profile **inspector**"（检查器）。

## 对照表（同一份 `srgb.icc`）

| 能力 | `enanandesu/icc@0.1.1` | 本项目 `qqq66668/moon_icc` |
|---|---|---|
| 在当前工具链安装 | ❌ 旧包格式，`moon add` 直接失败 | ✅ `moon add qqq66668/moon_icc`（全新工程实拉通过，见 `tools/verify_publish.py`） |
| 在当前工具链编译 | ❌ 旧语法，迁移后仍报错 | ✅ CI 三后端（wasm-gc / js / native）全绿 |
| 返回类型 | `Map[String, String]`（元数据） | 数值：PCS XYZ、CMYK 四通道、ΔE |
| 读头部与 tag 表 | ✅ | ✅ |
| 设备值 → PCS XYZ | ❌ 无此能力 | ✅ `to_pcs(0.5,0.5,0.5)` → `0.20640003241890215 0.21403939749252843 0.17660683523992873` |
| 跨类型链接到 CMYK | ❌ 无此能力 | ✅ 输出四通道数值（CLI `link` 逐级灰阶，如 i=1 → `1 2 1 255`） |
| 渲染意图（四种） | ❌ 无此能力 | ✅ 含绝对比色（对 lcms2 197/200 完全一致） |
| 软打样 / 色域判定 | ❌ 无此能力 | ✅ 见 README 与 `CONFORMANCE.md` |

## 结论（净贡献）

1. **同名同类包不能完成任何颜色变换**——它的 API 只产出元数据字符串；
2. **它当前无法被使用**（包格式与语言语法两处都已过时），而本库可以在全新工程里
   `moon add` 后立刻跑出数值结果；
3. 本库补上**从 profile 到数值结果这一段**：matrix/TRC 与 LUT 变换、跨类型链接
   （含 CMYK 四通道输出）、四种渲染意图、软打样与色域判定。

**更正（2026-10-30）**：本文件初版在结论第 3 条写过「这些在 mooncakes 上此前没有
任何 MoonBit 实现」。该表述**不成立**——`moonbitlang/typst/moxcms` 已提供真实的
ICC 解析与 LUT 变换。下面一节用可核查的方式给出与它的差异，替代那句断言。

## 与 `moonbitlang/typst/moxcms` 的关系（2026-10-30 核查）

核查方式：用 `gh api` 直读 `repos/moonbitlang/typst.mbt` 的源码与
`moxcms/pkg.generated.mbti`（Apache-2.0；`moxcms/` 目录含 `profile.mbt` 1007 行、
`reader.mbt` 903 行、`mab.mbt` 285 行、`lut_transforms.mbt` 297 行、
`rgbxyz.mbt` 317 行、`tag.mbt` 148 行，另有独立 `pxfm/` 浮点数学子包与
Rust oracle `moxcms/oracle/src/main.rs`）。

**它确实做的事**（实质重叠，不回避）：ICC profile 解析、matrix/shaper 判定
（`ColorProfile::is_matrix_shaper`）、`A2B*`/`B2A*` LUT 与 `mAB`/`mBA` 变换、
8 位与 f32 两条执行器（`create_transform_8bit` / `create_transform_f32`）、
RGB↔XYZ 矩阵、`RenderingIntent` 枚举、GAMUT tag 读取。

**本次核查中未在其公开面看到的能力**（均为「未见」，不是「一定没有」）：

| 能力 | 本项目 | `moxcms`（公开 API 与相关源码） |
|---|---|---|
| 命名色 `ncl2` 解析与色名→PCS 查表 | ✅ `Profile::named_colors()` / `lookup_lab()` | 未见：`pkg.generated.mbti` 的 19 个 `pub fn` 中无命名色入口；`tag.mbt` 的 tag 分派表只列 `A2B*`/`B2A*`/GAMUT |
| 软打样链（源→打样→显示） | ✅ `ColorTransform::proofing` | 未见：`proof` 在 `profile.mbt`/`reader.mbt`/`tag.mbt`/`mab.mbt` 均无命中 |
| 色域边界判定（含 3/4 通道设备） | ✅ `GamutBoundary` + 有符号距离 | 未见：`gamut` 仅作 `LutWarehouse` 字段承载 GAMUT tag，无边界查询 API |
| `abst` / `link` 变换入口 | ✅ `apply_abstract` / `apply_device_link` | 未见：设备类枚举含 `Abstract`/`Named`，但无对应变换入口 |
| 四种意图的逐样本 lcms2 金标对拍 | ✅ 200 样本 × 4 意图 | 未见公开对拍记录；其 oracle 是 Rust 实现 |
| 定位 | 设备↔PCS 数值变换 + 色名查表 + 打样/色域 | 通用 CMS 内核（供 typst 排版链使用） |

**差异陈述（不使用「生态空缺」这类无条件断言）**：两者在「解析 + LUT 变换」这一层
重叠；本项目的可核查增量集中在命名色查表、软打样链、色域边界判定、`abst`/`link`
入口，以及面向 lcms2 的逐样本对拍记录（`COMPARISON.md`、`CONFORMANCE.md`、
`MUTATION.md`）。两者许可相同（Apache-2.0），本项目**未使用其任何源码**。

**其他相关包**：`0717lee/moonav1` 的 `examples/color_video` 演示了「ICC 相对比色 +
黑点补偿」的用法，属**下游使用者**而非 CMS 实现；`enanandesu/icc` 见上文。

## 复现方式

```bash
# 1) 复现"装不上"
mkdir /tmp/icc_compare && cd /tmp/icc_compare
# 写 moon.mod（name = "verify/icc_compare"）
moon add enanandesu/icc

# 2) 复现"本库可用"
python tools/verify_publish.py     # 在仓库之外的空工程里实拉并跑真实变换

# 3) 复现"它的 API 只有元数据"
moon view enanandesu/icc           # 描述即 "parse ICC profiles"
# 源码：https://github.com/enanandesu/icc 的 icc.mbt
```
