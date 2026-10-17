///|
/// ICC v4 的 `mAB ` / `mBA ` LUT 测试。
///
/// 判据分三层，逐层收窄"错在哪"：
///
/// 1. **结构**：类型分派、通道数、网格点数、曲线条数。这一层能抓住
///    "把 `mAB ` 当 `mft2` 解析"这类整体性错误。
/// 2. **节点**：`A2B0` 的 A/M/B 曲线与矩阵**全部恒等**，因此其输出
///    应当精确等于 CLUT 节点值。节点值由测试**直接读原始字节**得到
///    （用独立分析得出的偏移），不经过本库的解析代码——这样就把
///    「矩阵段没有类型签名头」（偏移 80 处直接是矩阵，不是"签名 + 矩阵"）
///    与「内嵌曲线段没有长度字段」两处同时钉死。
/// 3. **端到端**：40 个样本与 lcms2 对拍（A2B 直接对 `RGB -> LAB`；
///    B2A 用 `RGB -> RGB` 组合变换，避开 lcms2 8 位 Lab 输入格式器的坐标偏移）。
///
/// ## 为什么 B2A 不用 `LAB` 模式对拍
///
/// 实测：用一个"CLUT 恒等 + 曲线恒等"的探针 profile 反解 lcms2 送进 CLUT
/// 的坐标，发现 8 位 Lab 输入在近黑处被抬高约 8/255（`L8=1` 时坐标是
/// 0.0353 而非 0.0039）。若不避开这个格式器，会把 lcms2 的行为记成本库的误差。

///|
/// 读取 v4 对拍样本 profile。
fn v4_profile() -> Profile raise {
  Profile::parse(@fs.read_file_to_bytes("testdata/test4.icc"))
}

///|
/// 取 v4 分支的表（测试用）。
fn as_v4_table(t : LutTable) -> V4Lut {
  match t {
    LutV4(v) => v
    LutV2(_) => abort("期望 v4 的 mAB/mBA 表，实得 v2 的 mft1/mft2")
  }
}

///|
/// 把 Lab 量化成 Pillow LAB 模式的 8 位表示（复用 `clut_wbtest.mbt` 的实现）。
/// 这里单独声明一个别名以免与同包的 `lab_to_pillow` 重名。
fn v4_lab_to_8(lab : Lab) -> (Int32, Int32, Int32) {
  lab_to_pillow(lab)
}

///|
/// 结构判据：v4 的四个 LUT tag 必须被识别为 v4 类型，且网格/通道数正确。
///
/// 若把 `mAB ` 误当 `mft2`（或反之），`type_name` 与 `grid_text` 会立刻不符；
/// 若曲线段的长度算错，`a_curves` 的条数也会不符。
test "v4 LUT: 类型分派与结构字段" {
  let profile = v4_profile()
  inspect(profile.header.major_version, content="4")
  inspect(profile.header.pcs, content="Lab ")
  // 设备 → PCS 的两个 tag
  let a0 = as_v4_table(profile.a2b(0))
  inspect(a0.input_channels, content="3")
  inspect(a0.output_channels, content="3")
  inspect(a0.grid.length(), content="3")
  inspect(a0.grid[0], content="17")
  inspect(profile.a2b(0).type_name(), content="mAB ")
  inspect(profile.a2b(0).grid_text(), content="17x17x17")
  // A2B1：2³ CLUT + 3 条 7 参数 para 曲线 + 3 条 2 项 curv
  let a1 = as_v4_table(profile.a2b(1))
  inspect(a1.grid[0], content="2")
  inspect(a1.a_curves.length(), content="3")
  inspect(a1.m_curves.length(), content="3")
  inspect(a1.b_curves.length(), content="3")
  inspect(profile.a2b(1).grid_text(), content="2x2x2")
  // PCS → 设备的两个 tag
  inspect(profile.b2a(0).type_name(), content="mBA ")
  inspect(profile.b2a(0).grid_text(), content="17x17x17")
  inspect(profile.b2a(1).grid_text(), content="2x2x2")
  let b1 = as_v4_table(profile.b2a(1))
  // mBA：B/M 用输入通道数（3），A 用输出通道数（3）
  inspect(b1.b_curves.length(), content="3")
  inspect(b1.m_curves.length(), content="3")
  inspect(b1.a_curves.length(), content="3")
}

///|
/// 节点判据：`A2B0` 的曲线与矩阵全为恒等，故节点处输出 = 节点存储值。
///
/// 期望值由测试**自己读原始字节**算出：`test4.icc` 的 `A2B0` tag 起始 372、
/// CLUT 段偏移 176、网格 17³、表值 16 位，故节点 `(i,j,k)` 的 ch0 位于
/// `372 + 176 + 20 + ((i*17 + j)*17 + k)*6`。这三个常量来自独立分析
/// （Python 解析 + 长度自洽验证），不经过本库代码。
///
/// 若实现把矩阵段按"8 字节类型头 + 矩阵"读，节点处的输出会立刻错位；
/// 若曲线段按"保留位当长度"推进，曲线条数或偏移也会错。
test "v4 LUT: A2B0 节点值与原始字节一致" {
  let data = @fs.read_file_to_bytes("testdata/test4.icc")
  let profile = v4_profile()
  let a0 = as_v4_table(profile.a2b(0))
  let tag_start = 372
  let clut_start = tag_start + 176 + 20
  // 采样若干节点，含三个端点与内点
  let nodes : Array[(Int32, Int32, Int32)] = [
    (0, 0, 0),
    (16, 16, 16),
    (8, 8, 8),
    (0, 16, 8),
    (16, 0, 8),
    (5, 11, 3),
  ]
  let mut worst = 0.0
  let mut worst_case = ""
  for node in nodes {
    let (i, j, k) = node
    let at = clut_start + ((i * 17 + j) * 17 + k) * 6
    // 独立读出三个通道的 16 位原始值，按 v4 Lab 编码换算
    let r0 = (data[at].to_int() << 8) | data[at + 1].to_int()
    let r1 = (data[at + 2].to_int() << 8) | data[at + 3].to_int()
    let r2 = (data[at + 4].to_int() << 8) | data[at + 5].to_int()
    let want_l = r0.to_double() / 65535.0 * 100.0
    let want_a = r1.to_double() / 65535.0 * 255.0 - 128.0
    let want_b = r2.to_double() / 65535.0 * 255.0 - 128.0
    // 输入取节点位置：v = 索引/(17-1)，四面体/三线性在节点上都精确命中
    let inputs : Array[Double] = [
      i.to_double() / 16.0,
      j.to_double() / 16.0,
      k.to_double() / 16.0,
    ]
    let lab = clut_output_to_lab(
      a0.evaluate(inputs),
      profile.a2b(0).bit_depth(),
      profile.a2b(0).pcs_is_v2(profile.is_v2()),
    )
    let d = @cmp.maximum(
      @cmp.maximum((lab.l - want_l).abs(), (lab.a - want_a).abs()),
      (lab.b - want_b).abs(),
    )
    if d > worst {
      worst = d
      worst_case = "节点(\{i},\{j},\{k}) 期望(\{want_l},\{want_a},\{want_b}) 实得(\{lab.l},\{lab.a},\{lab.b})"
    }
  }
  // 节点上插值权重为 0，差异只应来自浮点结合顺序
  if worst > 1.0e-6 {
    fail("A2B0 节点最大偏差 \{worst} 超过 1e-6: \{worst_case}")
  }
}

///|
/// 端到端判据：A2B 方向（设备 RGB → PCS Lab）与 lcms2 对拍。
///
/// 两个意图各 40 个样本（端点、原色、灰阶与固定种子的伪随机值）。
/// 容差按 8 位量化设定（≤1 级），并要求完全一致率达到阈值。
fn check_a2b(intent : Int32, cases : Array[V4A2BCase]) -> Unit raise {
  let profile = v4_profile()
  let mut worst = 0
  let mut exact = 0
  let mut worst_case = ""
  for case in cases {
    let inputs : Array[Double] = [
      case.r.to_double() / 255.0,
      case.g.to_double() / 255.0,
      case.b.to_double() / 255.0,
    ]
    let lab = profile.device_to_lab(intent, inputs)
    let (lp, ap, bp) = v4_lab_to_8(lab)
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
  let total = cases.length()
  if worst > 1 {
    fail(
      "A2B(intent \{intent}) 最大偏差 \{worst} 级超过 1: \{worst_case}",
    )
  }
  if exact * 10 < total * 9 {
    fail("A2B(intent \{intent}) 完全一致率过低：\{exact}/\{total}")
  }
}

///|
/// 端到端判据：B2A 方向（PCS Lab → 设备）与 lcms2 对拍。
///
/// 用 `profile -> profile` 的组合变换取参考值（内部先 A2B 再 B2A），
/// 这样参考值不经过 lcms2 的 8 位 Lab 输入格式器。
/// 该判据同时钉住 `mBA` 的**阶段顺序**（B → 矩阵 → M → CLUT → A）：
/// 顺序写错时，含非恒等矩阵的 `B2A1` 会立刻超差。
fn check_b2a(intent : Int32, cases : Array[V4B2ACase]) -> Unit raise {
  let profile = v4_profile()
  let transform = ColorTransform::with_intent(profile, profile, intent)
  let mut worst = 0
  let mut exact = 0
  let mut worst_case = ""
  for case in cases {
    let out = transform.transform_values([
      case.r.to_double() / 255.0,
      case.g.to_double() / 255.0,
      case.b.to_double() / 255.0,
    ])
    let to8 = fn(x : Double) -> Int32 {
      clamp_i((x * 255.0 + 0.5).to_int(), 0, 255)
    }
    let or_ = to8(out[0])
    let og = to8(out[1])
    let ob = to8(out[2])
    let d = @cmp.maximum(
      @cmp.maximum((or_ - case.out_r).abs(), (og - case.out_g).abs()),
      (ob - case.out_b).abs(),
    )
    if d == 0 {
      exact = exact + 1
    }
    if d > worst {
      worst = d
      worst_case = "RGB(\{case.r},\{case.g},\{case.b}) lcms2=(\{case.out_r},\{case.out_g},\{case.out_b}) 本库=(\{or_},\{og},\{ob})"
    }
  }
  let total = cases.length()
  if worst > 1 {
    fail(
      "B2A(intent \{intent}) 最大偏差 \{worst} 级超过 1: \{worst_case}",
    )
  }
  if exact * 10 < total * 8 {
    fail("B2A(intent \{intent}) 完全一致率过低：\{exact}/\{total}")
  }
}

///|
/// A2B 感知意图端到端。
test "v4 LUT: A2B0 与 lcms2 一致" {
  check_a2b(0, v4_a2b0_golden)
}

///|
/// A2B 媒体相对比色端到端（覆盖 7 参数 para 曲线与 2³ CLUT）。
test "v4 LUT: A2B1 与 lcms2 一致" {
  check_a2b(1, v4_a2b1_golden)
}

///|
/// B2A 感知意图端到端（覆盖 17³ CLUT 的三线性插值）。
test "v4 LUT: B2A0 与 lcms2 一致" {
  check_b2a(0, v4_b2a0_golden)
}

///|
/// B2A 媒体相对比色端到端（覆盖矩阵段与参数曲线）。
test "v4 LUT: B2A1 与 lcms2 一致" {
  check_b2a(1, v4_b2a1_golden)
}

///|
/// 两个意图必须选中不同的 tag。
///
/// 实测：本样本 profile 的 `A2B0` 与 `A2B1` 在 40 个样本里有 38 个结果不同，
/// `B2A0` 与 `B2A1` 有 8 个不同——若意图映射失效，这条判据会红。
test "v4 LUT: 意图映射有效" {
  let profile = v4_profile()
  let sample : Array[Double] = [0.4, 0.6, 0.2]
  let l0 = profile.device_to_lab(0, sample)
  let l1 = profile.device_to_lab(1, sample)
  if (l0.l - l1.l).abs() < 1.0e-9 &&
    (l0.a - l1.a).abs() < 1.0e-9 &&
    (l0.b - l1.b).abs() < 1.0e-9 {
    fail("A2B0 与 A2B1 在该样本上结果相同，意图映射可能失效")
  }
}

///|
/// 缺失输入通道按 0 补齐，多余输入被忽略（v4 路径同样要安全）。
test "v4 LUT: 通道数不足/多余都安全" {
  let profile = v4_profile()
  let table = profile.a2b(0)
  let full : Array[Double] = [0.3, 0.0, 0.0]
  let partial : Array[Double] = [0.3]
  let extra : Array[Double] = [0.3, 0.0, 0.0, 0.9, 0.9]
  let a = table.evaluate(full)
  let b = table.evaluate(partial)
  let c = table.evaluate(extra)
  for i = 0; i < a.length(); i = i + 1 {
    if (a[i] - b[i]).abs() > 1.0e-15 {
      fail("输入不足时结果与补 0 不一致")
    }
    if (a[i] - c[i]).abs() > 1.0e-15 {
      fail("多余输入通道影响了结果")
    }
  }
}

///|
/// 类型不符时必须显式报错：拿 `mBA ` 去解析 A2B 方向、拿 `mAB ` 去解析 B2A 方向。
///
/// 这是解析层的守卫：`mAB ` 与 `mBA ` 的段顺序相反，混用会静默给出错误颜色。
test "v4 LUT: 方向不符时显式报错" {
  let profile = v4_profile()
  let a2b0 = match profile.find_tag("A2B0") {
    Some(t) => t
    None => abort("样本 profile 缺少 A2B0")
  }
  let b2a0 = match profile.find_tag("B2A0") {
    Some(t) => t
    None => abort("样本 profile 缺少 B2A0")
  }
  try parse_v4_lut(profile.data, a2b0, BToA) catch {
    BadTagData(..) => ()
    e => fail("把 mAB 当 mBA 解析应报 BadTagData，实际: \{e}")
  } noraise {
    _ => fail("把 mAB 当 mBA 解析不应成功")
  }
  try parse_v4_lut(profile.data, b2a0, AToB) catch {
    BadTagData(..) => ()
    e => fail("把 mBA 当 mAB 解析应报 BadTagData，实际: \{e}")
  } noraise {
    _ => fail("把 mBA 当 mAB 解析不应成功")
  }
}

///|
/// 写一个字节。
fn push_byte(buf : @buffer.Buffer, v : Int32) -> Unit {
  buf.write_byte(v.to_byte())
}

///|
/// 写一个大端 u16。
fn push_u16(buf : @buffer.Buffer, v : Int32) -> Unit {
  push_byte(buf, v >> 8)
  push_byte(buf, v)
}

///|
/// 写一个大端 u32。
fn push_u32(buf : @buffer.Buffer, v : Int32) -> Unit {
  push_byte(buf, v >> 24)
  push_byte(buf, v >> 16)
  push_byte(buf, v >> 8)
  push_byte(buf, v)
}

///|
/// 写 4 个字节的签名（这里只用 ASCII 常量）。
fn push_sig(
  buf : @buffer.Buffer,
  a : Int32,
  b : Int32,
  c : Int32,
  d : Int32,
) -> Unit {
  push_byte(buf, a)
  push_byte(buf, b)
  push_byte(buf, c)
  push_byte(buf, d)
}

///|
/// **曲线段对齐**：`test4.icc` 的曲线段长度恰好都是 4 的倍数，
/// 因此它的金标**测不出**"曲线段要补齐到 4 字节边界"这条规则。
/// 这里用合成 tag 补上这个缺口。
///
/// 合成的 `mAB ` tag 结构：
///
/// - A 段：3 条 `curv`，各为**单值 gamma**（`0x0200` = 2.0），
///   段长 `8 + 4 + 2 = 14` 字节，**必须补齐到 16**；
/// - M 段：3 条 `para` gamma 1.0（16 字节，本来对齐）；
/// - CLUT：2×2×2，全部节点恒为 0.5（与插值方式无关，便于分离"解析"与"插值"）；
/// - 矩阵段与 B 段缺省（偏移为 0）。
///
/// 若不做 4 字节补齐，第二条曲线会从第 14 字节开始读，
/// 那里是补齐用的 0 字节，签名不再是 `curv`，解析会直接失败或读出错误 gamma。
test "v4 LUT: 曲线段必须补齐到 4 字节边界（合成 tag）" {
  let buf = @buffer.Buffer()
  // tag 头：类型 + 保留 + 入/出通道 + 2 字节保留
  push_sig(buf, 0x6D, 0x41, 0x42, 0x20) // "mAB "
  push_u32(buf, 0)
  push_byte(buf, 3)
  push_byte(buf, 3)
  push_u16(buf, 0)
  // 5 个偏移占位：B, Mat, M, C, A
  let off_pos = 12
  push_u32(buf, 0) // B 缺省
  push_u32(buf, 0) // 矩阵缺省
  push_u32(buf, 80) // M
  push_u32(buf, 128) // CLUT
  push_u32(buf, 32) // A
  // A 段：3 条单值 gamma=2.0 的 curv，各 14 字节 + 2 字节补齐
  for i = 0; i < 3; i = i + 1 {
    push_sig(buf, 0x63, 0x75, 0x72, 0x76) // "curv"
    push_u32(buf, 0)
    push_u32(buf, 1) // 项数 1 = 单值 gamma
    push_u16(buf, 0x0200) // u8Fixed8 = 2.0
    push_u16(buf, 0) // 补齐
  }
  // M 段：3 条 para 函数类型 0（gamma），参数 1.0
  for i = 0; i < 3; i = i + 1 {
    push_sig(buf, 0x70, 0x61, 0x72, 0x61) // "para"
    push_u32(buf, 0)
    push_u16(buf, 0) // 函数类型 0
    push_u16(buf, 0)
    push_u32(buf, 65536) // s15Fixed16 = 1.0
  }
  // CLUT 段：2×2×2，节点全为 0.5（0x8000）
  for i = 0; i < 16; i = i + 1 {
    push_byte(buf, if i < 3 { 2 } else { 0 })
  }
  push_byte(buf, 2) // 精度 2 字节
  push_byte(buf, 0)
  push_byte(buf, 0)
  push_byte(buf, 0)
  for i = 0; i < 24; i = i + 1 {
    push_u16(buf, 0x8000)
  }
  let data = buf.to_bytes()
  // 前提检查：A 段第一条曲线确实从 32 开始、长度为 14（非 4 的倍数）
  if data[32].to_int() != 0x63 {
    fail("合成 tag 的 A 段偏移不对")
  }
  let entry : IccTagEntry = {
    signature: "A2B0",
    offset: 0,
    size: data.length(),
  }
  // 解析包一层：不做补齐时，第二条曲线会从满是 0 的补齐区开始读，
  // 报出的类型签名会含 NUL 字节（测试驱动无法解析这种结果消息），
  // 因此在这里捕获并换成纯 ASCII 的失败消息。
  let table = try parse_v4_lut(data, entry, AToB) catch {
    e =>
      fail(
        "合成 tag 解析失败（很可能是曲线段未按 4 字节补齐）：\{e}",
      )
  } noraise {
    t => t
  }
  inspect(table.input_channels, content="3")
  inspect(table.output_channels, content="3")
  inspect(table.a_curves.length(), content="3")
  inspect(table.m_curves.length(), content="3")
  inspect(table.matrix.length(), content="0")
  // gamma 2.0：0.5 -> 0.25
  for c in table.a_curves {
    let y = c.evaluate(0.5)
    if (y - 0.25).abs() > 1.0e-9 {
      fail("A 曲线 gamma 解析错误：期望 0.25，实得 \{y}")
    }
  }
  // 节点全为 0.5，故任何输入都得到 0.5 —— 这一条与插值方式无关
  let out = table.evaluate([1.0, 1.0, 1.0])
  for v in out {
    if (v - 32768.0 / 65535.0).abs() > 1.0e-12 {
      fail("常量 CLUT 的输出应为 32768/65535，实得 \{v}")
    }
  }
  let _ = off_pos
}
