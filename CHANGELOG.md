# 更新日志

本项目版本发布记录。所有版本已发布至 mooncakes.io，发布时点可逐条核对：

```
~/.moon/registry/index/user/qqq66668/moon_icc.index
```

该索引每行一个版本，含 `created_at`、`checksum`、`license`、`repository`、
`preferred-target` 与依赖声明。下文的时间均取自该索引，不是估计值。

## 0.3.2 — 2026-10-31

**变更**

- README 验收修正：测试数 93 → **104**；CLI 子命令数四 → **八**；命令行示例补
  `named` 与 `conformance`；「当前进度」表补 `ncl2` 数据体、命名色、`abst`/`link`
  三行；`moon test --target native` 补本机限制说明（Windows 缺 MSVC，以 CI 为准）。
- `.gitignore` 补 `*.generated.mbti` 忽略规则。
- 仓库 36 个提交；CI run `41181248676`（head `2d3ea31`）success。

**验证**

- `moon test --target wasm-gc` 与 `--target js` 各 **104/104**；
  `moon fmt --check` / `moon check --target wasm-gc --deny-warn` / `moon build` 全 0 退出。

## 0.3.1 — 2026-10-30

注册表 `created_at`：`2026-10-30T13:14:55Z`

**新增**

- **命名色（`nmcl` 类 / `ncl2` tag）**：`ncl2` 全字段解析——`vendorFlag`、`count`、
  `nDeviceCoords`（0..8，超出报 `BadTagData`）、`prefix`、`suffix`、每条 `rootName`、
  PCS 三分量、`nDeviceCoords × u16` 设备坐标。
- 色名 → PCS 查表：`Profile::named_colors()`、`NamedColor2::lookup()`、
  `NamedColor2::lookup_lab()`。**完整色名 = `prefix + rootName + suffix`**，
  裸根名不命中（否则同根名、不同后缀的条目无法区分）。
- PCS 按 profile 头部与版本解码：`Lab ` 用 v4 上限 `0xFFFF` / v2 上限 `0xFF00`；
  `XYZ ` 用 `u1Fixed15Number`（1.0 = `0x8000`）。
- 合成夹具 `testdata/named_lab.icc` / `named_xyz.icc`，由
  `tools/gen_named_profile.py` 确定性生成（同色名、同设备坐标，仅 PCS 编码空间不同）。
- CLI 新子命令 `named`：打印 `ncl2` 字段与逐条「完整色名 → Lab + 设备坐标」，
  并演示完整名命中 / 裸根名不命中。

**变更**

- 一致性矩阵中 `nmcl` 由「不作为目标」改为「本次实现」；新增测试锁死
  「7 个设备类全部为本次实现」，任何回退立即变红。
- 测试 96 → **104**（新增 8 条命名色判据，含截断与错类型签名负例）。
- `README.md` 新增「开发回顾」小节：关键架构决策、AI 参与环节与边界、参考来源与许可。
- `CONFORMANCE.md` 新增「数字复现命令」表（每个对外数字对应的命令）。
- `testdata/README.md` 为 `test4.icc` 补 commit pin。

**验证**

- `moon test --target wasm-gc` 与 `--target js` 各 **104/104**；
  `moon fmt --check` / `moon check --target wasm-gc --deny-warn` / `moon build` 全 0 退出。
- 第三方对拍：lcms2 `cmsNamedColorInfo` 逐条 u16，两份夹具各 **5/5 完全相同**
  （PCS 与设备坐标都对上）。
- 变异测试：`named_color2_entry_base` 38 → 44，**5 条命名色用例全红**（见 `MUTATION.md`）。
- 干净环境实拉：全新工程 `moon add qqq66668/moon_icc@0.3.1` 后运行，输出
  `classes 7` / `nmcl -> 本次实现`，exit 0。

## 0.3.0 — 2026-10-23

注册表 `created_at`：`2026-10-23T14:32:45Z`。

该版本的能力清单与逐条判据对应见 `CONFORMANCE.md`，变异测试记录见 `MUTATION.md`。

## 0.2.0 — 2026-10-20

注册表 `created_at`：`2026-10-20T15:48:31Z`。

## 0.1.0 — 2026-10-17

注册表 `created_at`：`2026-10-17T08:21:40Z`。首个公开发布版本。

## 关于 0.1.0–0.3.0 的记录口径

这三个版本发布时没有逐条留存变更记录，因此本文件**不对其内容作回溯性描述**——
凭印象补写等于编造。各版本的实际内容可直接核对快照：

```bash
moon add qqq66668/moon_icc@0.1.0   # 换成 0.2.0 / 0.3.0 即可看对应快照
```

## 版本规则

- 版本号遵循 `MAJOR.MINOR.PATCH`，与 `moon.mod` 的 `version` 一致。
- 已发布版本不可修改（工具链事实），修正只能发新版本。
- 每次发布后需在全新工程 `moon add` 实拉一次并跑通 README 示例，不只看发布回显。
