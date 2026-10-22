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

1. **唯一同类包不能完成任何颜色变换**——它的 API 只产出元数据字符串；
2. **它当前无法被使用**（包格式与语言语法两处都已过时），而本库可以在全新工程里
   `moon add` 后立刻跑出数值结果；
3. 因此本库的净贡献不是"比它多一点功能"，而是**补上从 profile 到数值结果这一段**：
   matrix/TRC 与 LUT 变换、跨类型链接（含 CMYK 四通道输出）、四种渲染意图、
   软打样与色域判定——这些在 mooncakes 上此前没有任何 MoonBit 实现。

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
