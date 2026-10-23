# 一致性目标与覆盖说明

本文件明确回答两个问题：**本项目对照哪个规范版本**、**哪些必需行为已覆盖、
哪些不做**。所有"已验证"的结论都能用仓库内的命令与测试复现。

自查命令：

```bash
moon run cmd/main --target wasm-gc -- conformance                 # 打印覆盖矩阵
moon run cmd/main --target wasm-gc -- conformance testdata/xxx.icc # 检查单个 profile 的必需 tag
moon test --target wasm-gc                                        # 93 项测试
```

## 1. 目标规范版本

| 项 | 取值 |
|---|---|
| 目标规范 | **ICC.1:2010-12（ISO 15076-1:2010）**，profile version **4.3** |
| 向下兼容 | **ICC.1:2001-04（v2.x）**：v2/v4 的 PCS Lab 编码差异（上限 `0xFF00` vs `0xFFFF`）已实现并各有判据 |
| PCS | 固定 **D50**；支持 `XYZ `（u1Fixed15 编码）与 `Lab `（v2/v4 编码不同） |
| 明确排除 | **iccMAX（ICC.2）**：架构不同（多 PCS、光谱数据），不是本库的范围；**profile v5**：不存在该版本号 |

## 2. 设备类覆盖矩阵

三态，刻意区分"实现了"与"有真实样本验证过"：

| 设备类 | 含义 | 支持水平 | 说明 |
|---|---|---|---|
| `scnr` | 输入设备 | **已验证** | 设备 → PCS（matrix/TRC 或 A2B LUT） |
| `mntr` | 显示设备 | **已验证** | 设备 ↔ PCS（A2B/B2A；matrix/TRC 可逆） |
| `prtr` | 输出设备 | **已验证** | PCS → 设备（B2A），并支持 A2B 用于打样链 |
| `spac` | 工作空间 | **已验证** | 设备 ↔ PCS；matrix/TRC 与 LUT 两种都验证过 |
| `abst` | 抽象 profile | **已验证** | PCS → PCS（`Profile::apply_abstract`）；**恒等**合成样本 + 解析式判据 |
| `link` | 设备链接 | **已验证** | 设备 → 设备（`Profile::apply_device_link`）；RGB→CMYK **解析式**合成样本 + 判据 |
| `nmcl` | 命名色 | **不支持** | 需要 `ncl2` 命名色查表，与"设备色彩变换"是两条路 |

"已验证"的判据：仓库里有该类的**真实 profile**，且测试同时覆盖解析、变换与外部对拍
（见第 5 节的对应表）。`conformance` 子命令会对你给的任何 profile 重新做一次必需 tag 检查。

## 3. 各类的必需行为

### 3.1 头部与 tag 表

- 128 字节头部：9 个字段全部解析，含版本、设备类、色空间、PCS、创建时间、
  `acsp` 签名、平台、标志、厂商/型号、渲染意图、PCS 照明体；
- tag 表：条目数、每条 `offset + size` 边界校验、乘法溢出检查；
- 畸形输入返回结构化错误（`IccError` 六种）而不是 panic。

### 3.2 必需 tag（可执行检查）

`required_tags_for_class` 给出各类的**共同必需** tag，`class_required_sets` 给出
**候选集**（规范里"matrix/TRC 型 **或** LUT 型"的语义，任一 set 完整即可）：

| 设备类 | 共同必需 | 候选集（任一完整即可） |
|---|---|---|
| `scnr` / `mntr` / `spac` | `desc`、`cprt`、`wtpt` | `rXYZ+gXYZ+bXYZ+rTRC+gTRC+bTRC` **或** `A2B0` |
| `prtr` | `desc`、`cprt`、`wtpt` | `A2B0 + B2A0` |
| `abst` | `desc`、`cprt` | `A2B0` |
| `link` | `desc`、`cprt` | `A2B0` |
| `nmcl` | `desc`、`cprt`、`wtpt` | `ncl2`（本库不处理内容） |

本实现的简化，明确记录：只检查 tag **是否存在**，不检查 LUT 张数是否覆盖全部意图
（v4 输出类规范上要求 `A2B0-2` 与 `B2A0-2` 共 6 张）；报告的备注里会给出实有张数。

### 3.3 编码与版本差异

| 行为 | 状态 |
|---|---|
| `s15Fixed16Number` / `u1Fixed15Number` / `u16Fixed16Number` 读取 | ✅ |
| PCS `Lab ` 的 v2（上限 `0xFF00`）与 v4（`0xFFFF`）编码 | ✅ 分别有判据 |
| PCS `XYZ ` 的 u1Fixed15 编码（1.0 = `0x8000`） | ✅ 有常数判据 |
| LUT：v2 `mft1`/`mft2`、v4 `mAB `/`mBA ` | ✅ 对 lcms2 逐位对拍 |
| CLUT 多线性/四面体插值（按 lcms2 的方向规则） | ✅ |
| 矩阵段无类型签名头、内嵌曲线段无长度字段（v4 布局陷阱） | ✅ |

### 3.4 渲染意图与必需 API

| 行为 | 状态 |
|---|---|
| 四种意图（感知 / 相对 / 饱和度 / 绝对） | ✅ 全部实现并各有 lcms2 金标 |
| 绝对比色的 PCS 白点缩放 | ✅ 197/200 完全一致、最大 1 级 |
| 多 profile 级联（跨类型四种组合） | ✅ |
| 软打样链（源 → 打样设备往返 → 显示） | ✅ 对 lcms2 `cmsCreateProofingTransform` 最大 1 级 |
| 色域判定 | ✅ 几何色域边界（球面直方图）；设备值样本 0 误判 |
| 色域判定**面向不同设备** | ✅ 3 通道（显示器 profile）与 4 通道（CMYK 打印机）都能建边界并判定；**同一颜色在两台设备上结论不同**（sRGB 纯红：显示器界内、CMYK 界外）。注意采样密度需随设备调整：3 通道需 17³ 样本、4 通道需 9⁴ 样本才能达到 0 误判 |

## 4. 明确不做及理由

| 不做项 | 理由 |
|---|---|
| 命名色（`nmcl`） | `ncl2` 是命名色→PCS 的查表，与设备色彩变换是两条路 |
| iccMAX（ICC.2） | 架构不同（多 PCS、光谱、材质），需要独立设计 |
| 色貌模型（CAM） | 超出 ICC PCS 范围；PCS 已隐含观察条件 |
| 黑点补偿（BPC） | 其黑点检测需要迭代反查，尚未实现；文档与测试均不声称支持 |
| 图像容器读写（PNG/JPEG/TIFF） | 本库只处理色彩数值 |
| 不完全色适应（`AdaptationState != 1`） | 与 lcms2 默认（`AdaptationState = 1`）保持一致；绝对比色只做白点缩放 |

## 5. 判据与测试对应表

| 覆盖项 | 判据 |
|---|---|
| 头部/tag 表/边界防护 | `header_wbtest.mbt`；`tools/diff_oracle.py` 对 5 个真实 profile 逐字段比对 |
| matrix/TRC 与逆变换 | `transform_wbtest.mbt`；`link_golden_wbtest.mbt`（4096 样本对 lcms2） |
| LUT（`mft1`/`mft2`） | `clut_wbtest.mbt`（625 节点 + 300 样本对 lcms2） |
| LUT（`mAB `/`mBA `） | `v4lut_wbtest.mbt`（节点判据 + 40 样本）；`tools/diff_oracle.py` 独立结构对拍 |
| PCS `XYZ ` 的 LUT | `xyz_lut_wbtest.mbt`（编码常数 + 26 样本双向对拍） |
| 四种意图 | `intent_wbtest.mbt` + `intent_golden_wbtest.mbt`（200 样本 × 四意图） |
| 软打样 | `proofing_wbtest.mbt` + `proof_golden_wbtest.mbt`（C 版 lcms2 金标） |
| 色域判定 | `proofing_wbtest.mbt`（零误判、界内外分类、覆盖率、映射误差独立性） |
| 必需 tag 与设备类矩阵 | `conformance_wbtest.mbt` |
| `abst` / `link` | `abstract_link_wbtest.mbt`（恒等抽象不改变 PCS；device link 等于闭式 C=1-R…）|
| 色域边界的独立交叉验证 | `tools/compare_gamut.py`（lcms2 取 Lab + Python 重写球面直方图，一致率 91.7%）|

## 6. 已知边界（诚实清单）

1. **v2 `mft1`/`mft2` + `XYZ ` PCS**：代码路径共用同一解码器，但本机没有这种真实样本，
   因此没有单独判据；
2. **`abst` / `link`**：用**合成**样本验证（恒等抽象 + 解析式 device link），
   并由生成脚本当场复核 lcms2 可读；仍**没有真实世界的该类 profile**；
3. **`chad` tag**：绝对比色按 lcms2 的 `AdaptationState = 1` 语义只用 `wtpt`，
   不读 `chad`；这与参考实现默认行为一致，但不是"不完全适应"的实现；
4. **BPC**：未实现（见第 4 节）。

5. **色域判定的外部 oracle**：lcms2 自带的色域边界描述符 API 不能作为 oracle
   （实测 `cmsGDBCheckPoint` 对全部 24 个查询、含中灰都返回 out，而其边界侧
   6561 个样本全部接受、查询 Lab 值逐点核对正确——驱动见
   `_research/lcms_probe/lcms2_gdb.c`）。因此改用**独立第二实现**对拍：
   `tools/compare_gamut.py` 用 **lcms2 的 Lab 值 + Python 重写的球面直方图**
   与本库逐点比对，**一致率 91.7%（22/24）**；两处分歧是同一个颜色
   （sRGB 纯白，作角点与灰阶各出现一次），且都落在边界 3 个 Lab 单位内。
   结论：色域判据有独立交叉验证，但**没有与 CMM 内部算法逐位对拍的 oracle**。