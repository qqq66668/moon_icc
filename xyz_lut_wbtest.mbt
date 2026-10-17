///|
/// PCS 为 `XYZ ` 的 LUT 型 profile 的测试。
///
/// 样本是**合成**的 `testdata/xyz_lut.icc`（见 `tools/gen_xyz_lut_profile.py`）：
/// 本机与 lcms2 测试套件里带 LUT 的 profile 全是 `Lab ` PCS，
/// 没有 `XYZ ` PCS 的现成样本，因此合成一个结构完整、能被参考实现读取的文件。
///
/// 判据分三层：
///
/// 1. **结构**：PCS 字段、tag 类型、网格、位深；
/// 2. **编码常数**：XYZ 的 PCS 编码是 `u1Fixed15Number`（1.0 = `0x8000`）。
///    测试直接读文件的 CLUT 原始值，要求 `device_to_xyz` 恰为 `raw/32768`。
///    若误按满量程 `0xFFFF` 解释，结果会整体差 2 倍，这一层立刻变红。
/// 3. **端到端**：26 个样本与 lcms2 对拍（`RGB -> LAB` 与 `RGB -> RGB`），
///    并要求组合变换满足解析期望 `设备/1.99997…`。

///|
/// 读取合成 XYZ-PCS profile。
fn xyz_profile() -> Profile raise {
  Profile::parse(@fs.read_file_to_bytes("testdata/xyz_lut.icc"))
}

///|
/// 结构判据：PCS 必须是 `XYZ `，且表结构符合合成时的设计。
test "XYZ PCS: 结构字段" {
  let profile = xyz_profile()
  inspect(profile.header.pcs, content="XYZ ")
  inspect(profile.header.color_space, content="RGB ")
  inspect(profile.header.major_version, content="4")
  // 两侧都是 v4 的 mAB / mBA
  inspect(profile.a2b(0).type_name(), content="mAB ")
  inspect(profile.b2a(0).type_name(), content="mBA ")
  inspect(profile.a2b(0).grid_text(), content="2x2x2")
  inspect(profile.b2a(0).grid_text(), content="2x2x2")
  // CLUT 精度为 2 字节
  inspect(profile.a2b(0).bit_depth(), content="16")
}

///|
/// **编码常数判据**：XYZ 的 PCS 编码是 u1Fixed15（1.0 = 0x8000）。
///
/// 合成时 A2B0 的节点 `(i,j,k)` 写入的原始值就是 `(i,j,k)×32768`，
/// 所以正确实现下 `device_to_xyz` 必须恰好得到 `(i,j,k)`。
/// 测试同时**直接读文件字节**核对原始值，使这条判据不依赖"合成的意图"。
///
/// 判别力：把 32768 换成 65535（即按 u1Fixed16 解释），白点会从 XYZ=1.0
/// 变成 0.5，本判据立刻失败。
test "XYZ PCS: u1Fixed15 编码常数（含原始字节核对）" {
  let profile = xyz_profile()
  let entry = match profile.find_tag("A2B0") {
    Some(t) => t
    None => abort("合成 profile 缺少 A2B0")
  }
  // 合成布局：tag 头 12 + 偏移 20 = 32；A 曲线 3×12 = 36 → 68；
  // CLUT 段头 20 字节 → 数据自 tag 内偏移 88 起
  let clut_data = entry.offset + 88
  let nodes : Array[(Int32, Int32, Int32)] = [
    (0, 0, 0),
    (1, 1, 1),
    (0, 1, 0),
    (1, 0, 1),
    (0, 0, 1),
    (1, 1, 0),
  ]
  let data = profile.data
  let mut worst = 0.0
  let mut worst_case = ""
  for node in nodes {
    let (i, j, k) = node
    let at = clut_data + ((i * 2 + j) * 2 + k) * 6
    let r0 = (data[at].to_int() << 8) | data[at + 1].to_int()
    let r1 = (data[at + 2].to_int() << 8) | data[at + 3].to_int()
    let r2 = (data[at + 4].to_int() << 8) | data[at + 5].to_int()
    // 设备值取在网格节点上（2³ 网格的节点恰好是 0 与 1）
    let xyz = profile.device_to_xyz(0, [
      i.to_double(),
      j.to_double(),
      k.to_double(),
    ])
    // u1Fixed15：1.0 = 0x8000，故 XYZ = 原始值 / 32768
    let want_x = r0.to_double() / 32768.0
    let want_y = r1.to_double() / 32768.0
    let want_z = r2.to_double() / 32768.0
    let d = @cmp.maximum(
      @cmp.maximum((xyz.x - want_x).abs(), (xyz.y - want_y).abs()),
      (xyz.z - want_z).abs(),
    )
    if d > worst {
      worst = d
      worst_case = "节点(\{i},\{j},\{k}) 原始值(\{r0},\{r1},\{r2}) 期望(\{want_x},\{want_y},\{want_z}) 实得(\{xyz.x},\{xyz.y},\{xyz.z})"
    }
  }
  // 原始值是整数、换算是精确除法，差异只应来自浮点结合顺序
  if worst > 1.0e-9 {
    fail("XYZ 解码偏差 \{worst} 超过 1e-9: \{worst_case}")
  }
  // 语义检查：设备白点应落在 PCS 白点 D50 上（真实 profile 的行为）
  let white = profile.device_to_xyz(0, [1.0, 1.0, 1.0])
  if (white.x - 0.9642).abs() > 1.0e-4 ||
    (white.y - 1.0).abs() > 1.0e-4 ||
    (white.z - 0.8249).abs() > 1.0e-4 {
    fail(
      "设备白点未映射到 D50：实得 (\{white.x},\{white.y},\{white.z})",
    )
  }
}

///|
/// 端到端：设备 → PCS Lab 与 lcms2 对拍（26 个样本，8 位域）。
///
/// 这条路径同时覆盖"PCS 为 XYZ 的 LUT 解码"与"XYZ → Lab 换算"。
test "XYZ PCS: 设备 → PCS Lab 与 lcms2 一致" {
  let profile = xyz_profile()
  let mut worst = 0
  let mut exact = 0
  let mut worst_case = ""
  for case in xyz_a2b_golden {
    let lab = profile.device_to_lab(0, [
      case.r.to_double() / 255.0,
      case.g.to_double() / 255.0,
      case.b.to_double() / 255.0,
    ])
    let (lp, ap, bp) = lab_to_pillow(lab)
    let d = @cmp.maximum(
      @cmp.maximum((lp - case.lp).abs(), (ap - case.ap).abs()),
      (bp - case.bp).abs(),
    )
    if d == 0 {
      exact = exact + 1
    }
    if d > worst {
      worst = d
      worst_case = "RGB(\{case.r},\{case.g},\{case.b}) lcms2=(\{case.lp},\{case.ap},\{case.bp}) 本库=(\{lp},\{ap},\{bp})"
    }
  }
  if worst > 1 {
    fail("设备→Lab 最大偏差 \{worst} 级超过 1: \{worst_case}")
  }
  if exact * 10 < xyz_a2b_golden.length() * 9 {
    fail(
      "设备→Lab 完全一致率过低：\{exact}/\{xyz_a2b_golden.length()}",
    )
  }
}

///|
/// 端到端：组合变换（`A2B0` 后再 `B2A0`）与 lcms2 对拍，
/// 并核对解析期望 `设备 / 1.99997…`。
///
/// 该 profile 的两条管线都是线性斜坡，插值对线性函数是精确的，
/// 因此组合结果有闭式期望值——这是**不依赖任何参考实现**的独立判据。
test "XYZ PCS: 组合变换与 lcms2 及解析期望都一致" {
  let profile = xyz_profile()
  let transform = ColorTransform::with_intent(profile, profile, 0)
  let scale = 65535.0 / 32768.0
  let to8 = fn(x : Double) -> Int32 {
    clamp_i((x * 255.0 + 0.5).to_int(), 0, 255)
  }
  let mut worst_ref = 0
  let mut worst_analytic = 0
  let mut exact = 0
  for case in xyz_rgb2rgb_golden {
    let inputs : Array[Double] = [
      case.r.to_double() / 255.0,
      case.g.to_double() / 255.0,
      case.b.to_double() / 255.0,
    ]
    let out = transform.transform_values(inputs)
    let native : Array[Int32] = [to8(out[0]), to8(out[1]), to8(out[2])]
    let d_ref = @cmp.maximum(
      @cmp.maximum(
        (native[0] - case.out_r).abs(),
        (native[1] - case.out_g).abs(),
      ),
      (native[2] - case.out_b).abs(),
    )
    if d_ref == 0 {
      exact = exact + 1
    }
    if d_ref > worst_ref {
      worst_ref = d_ref
    }
    // 解析期望：输出 = 输入 × D50 / 1.99997…（8 位域，允许 1 级量化）
    for c = 0; c < 3; c = c + 1 {
      let white_c = if c == 0 { 0.9642 } else if c == 1 { 1.0 } else { 0.8249 }
      let want = to8(inputs[c] * white_c / scale)
      let d = (native[c] - want).abs()
      if d > worst_analytic {
        worst_analytic = d
      }
    }
  }
  if worst_ref > 1 {
    fail("组合变换与 lcms2 最大偏差 \{worst_ref} 级超过 1")
  }
  if worst_analytic > 1 {
    fail(
      "组合变换与解析期望（u1Fixed15）最大偏差 \{worst_analytic} 级超过 1",
    )
  }
  if exact * 10 < xyz_rgb2rgb_golden.length() * 9 {
    fail(
      "组合变换完全一致率过低：\{exact}/\{xyz_rgb2rgb_golden.length()}",
    )
  }
  // 判别力显式化：白点（设备 1.0）经 D50 与 1.99997 折算后应约为
  // (123, 128, 105)；若把 u1Fixed15 误当 u1Fixed16，三个通道都会翻倍。
  let white = transform.transform_values([1.0, 1.0, 1.0])
  let wr = to8(white[0])
  let wg = to8(white[1])
  let wb = to8(white[2])
  if wr > 125 || wr < 121 || wg > 130 || wg < 126 || wb > 107 || wb < 103 {
    fail(
      "白点经组合变换应约为 (123,128,105)，实得 (\{wr},\{wg},\{wb})",
    )
  }
}

///|
/// PCS 为 `XYZ ` 时 `device_to_lab` 与 `device_to_xyz` 必须自洽。
test "XYZ PCS: 两条解码路径自洽" {
  let profile = xyz_profile()
  let inputs : Array[Double] = [0.25, 0.5, 0.75]
  let xyz = profile.device_to_xyz(0, inputs)
  let lab = profile.device_to_lab(0, inputs)
  let back = xyz_to_lab(xyz)
  let d = @cmp.maximum(
    @cmp.maximum((lab.l - back.l).abs(), (lab.a - back.a).abs()),
    (lab.b - back.b).abs(),
  )
  if d > 1.0e-9 {
    fail("device_to_lab 与 device_to_xyz→xyz_to_lab 不一致，差 \{d}")
  }
}
