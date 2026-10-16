///|
/// CLUT 型 tag（`mft1` / `mft2`）的解析与求值。
///
/// ## 两种类型的布局
///
/// `mft2`（lut16Type，ICC v2 常用）：
///
/// | 偏移   | 大小 | 内容 |
/// |--------|------|------|
/// | 0..3   | 4    | `mft2` |
/// | 4..7   | 4    | 保留 |
/// | 8      | 1    | 输入通道数 |
/// | 9      | 1    | 输出通道数 |
/// | 10     | 1    | CLUT 网格点数 |
/// | 11     | 1    | 保留 |
/// | 12..47 | 36   | 矩阵 e1..e9（9 × s15Fixed16） |
/// | 48..49 | 2    | 输入表项数 |
/// | 50..51 | 2    | 输出表项数 |
/// | 52..   |      | 输入表（ic × in_entries × u16） |
/// |        |      | CLUT（gc^ic × oc × u16） |
/// |        |      | 输出表（oc × out_entries × u16） |
///
/// `mft1`（lut8Type）结构相同，但表项数固定为 256、表值类型为 u8，
/// 因此没有 48..51 的表项数字段，表直接从 48 开始。
///
/// ## 这条布局是实测确定的，不是照记忆写的
///
/// 起初按"表项数在 12..15、矩阵在 16..51"实现，结果与声明长度对不上
/// （差 2052 字节）。改用本文件记录的布局后：
/// `52 + 4×256×2 + 9^4×3×2 + 3×2×2 = 41478`，与本机 CMYK 打印机 profile
/// 的 A2B0 声明长度**精确相等**；且 12..47 处读到的是标准单位矩阵
/// `[1,0,0,0,1,0,0,0,1]`，48..51 读到的是 256 / 2。
///
/// ## 处理顺序
///
/// 输入表 → 矩阵（仅当输入通道数为 3）→ CLUT（多线性插值）→ 输出表。
///
/// 注意：本机可用的 LUT 型 profile 其矩阵均为单位矩阵，因此"矩阵在 CLUT
/// 之前还是之后"这一顺序**未被测试证据覆盖**。这里按 ICC 规格的字段顺序
/// 实现（矩阵先于 CLUT），若有反例应补充测试。

///|
/// 一个已解析的 CLUT 型 tag。
pub struct Clut {
  /// 输入通道数。
  input_channels : Int32
  /// 输出通道数。
  output_channels : Int32
  /// 网格点数（每个输入维度）。
  grid_points : Int32
  /// 表值位深：8（`mft1`）或 16（`mft2`）。
  ///|
  ///| 必须保留这个字段：PCS 输出的解码方式取决于它。
  ///| 例如 v2 的 Lab 编码在 16 位下上限是 0xFF00，在 8 位下上限是 0xFF。
  bit_depth : Int32
  /// 矩阵（行主序 9 项）；仅当 `input_channels == 3` 时使用。
  matrix : Array[Double]
  /// 输入表，按通道连续存放，值已归一化到 [0,1]。空数组表示恒等。
  input_tables : Array[Double]
  /// 每个通道的输入表项数（0 或 1 表示无表）。
  input_entries : Int32
  /// CLUT 节点值，按 (输入格点组合, 输出通道) 连续存放，归一化到 [0,1]。
  clut : Array[Double]
  /// 输出表，按通道连续存放，归一化到 [0,1]。空数组表示恒等。
  output_tables : Array[Double]
  /// 每个通道的输出表项数（0 或 1 表示无表）。
  output_entries : Int32
}

///|
/// 解析 `mft1` 或 `mft2` tag。其他类型报错。
pub fn parse_clut_tag(data : Bytes, entry : IccTagEntry) -> Clut raise IccError {
  let (type_sig, body_at) = tag_type_and_data(data, entry)
  match type_sig {
    "mft1" => parse_lut(data, entry, body_at, 8)
    "mft2" => parse_lut(data, entry, body_at, 16)
    _ =>
      raise BadTagData(
        tag=entry.signature,
        reason="期望 LUT 类型 \"mft1\" 或 \"mft2\"，实际 \"\{type_sig}\"",
      )
  }
}

///|
/// 解析 LUT 公共部分。
///
/// `bit_depth` 为 8（mft1）或 16（mft2）。
fn parse_lut(
  data : Bytes,
  entry : IccTagEntry,
  body_at : Int32,
  bit_depth : Int32,
) -> Clut raise IccError {
  let r = BigEndianReader::new(data)
  r.seek(body_at)
  let input_channels = r.read_u8()
  let output_channels = r.read_u8()
  let grid_points = r.read_u8()
  // 保留位
  r.skip(1)
  if input_channels < 1 || output_channels < 1 {
    raise BadTagData(
      tag=entry.signature,
      reason="通道数非法: 输入 \{input_channels} 输出 \{output_channels}",
    )
  }
  if grid_points < 2 {
    raise BadTagData(
      tag=entry.signature,
      reason="CLUT 网格点数 \{grid_points} 小于 2，无法做插值",
    )
  }
  // 矩阵：9 个 s15Fixed16
  let matrix : Array[Double] = []
  for i = 0; i < 9; i = i + 1 {
    matrix.push(r.read_s15f16())
  }
  // 表项数：mft1 固定 256，mft2 显式给出
  let (input_entries, output_entries) = if bit_depth == 8 {
    (256, 256)
  } else {
    let ie = r.read_u16()
    let oe = r.read_u16()
    (ie, oe)
  }
  // 输入表
  let input_tables = read_table(r, input_channels, input_entries, bit_depth)
  // CLUT
  // CLUT 节点数 = gc^ic × oc。用循环计算并设上限：
  // profile 是外部不可信输入，畸形的通道数/网格点数会试图分配巨量内存。
  let mut nodes_per_output = 1
  for i = 0; i < input_channels; i = i + 1 {
    nodes_per_output = nodes_per_output * grid_points
    if nodes_per_output > 1_000_000 {
      raise BadTagData(
        tag=entry.signature,
        reason="CLUT 节点数超过上限（网格 \{grid_points}^\{input_channels}），疑似畸形 profile",
      )
    }
  }
  let node_count = nodes_per_output * output_channels
  let clut : Array[Double] = []
  for i = 0; i < node_count; i = i + 1 {
    clut.push(read_table_value(r, bit_depth))
  }
  // 输出表
  let output_tables = read_table(r, output_channels, output_entries, bit_depth)
  {
    input_channels,
    output_channels,
    grid_points,
    bit_depth,
    matrix,
    input_tables,
    input_entries,
    clut,
    output_tables,
    output_entries,
  }
}

///|
/// 读一张表（`channels` 个通道，每通道 `entries` 项），归一化到 [0,1]。
///
/// `entries` 为 0 或 1 表示该表不参与运算（恒等），返回空数组。
fn read_table(
  r : BigEndianReader,
  channels : Int32,
  entries : Int32,
  bit_depth : Int32,
) -> Array[Double] raise IccError {
  if entries <= 1 {
    return []
  }
  let out : Array[Double] = []
  for c = 0; c < channels; c = c + 1 {
    for i = 0; i < entries; i = i + 1 {
      out.push(read_table_value(r, bit_depth))
    }
  }
  out
}

///|
/// 读一个表项并归一化。
fn read_table_value(
  r : BigEndianReader,
  bit_depth : Int32,
) -> Double raise IccError {
  if bit_depth == 8 {
    r.read_u8().to_double() / 255.0
  } else {
    r.read_u16().to_double() / 65535.0
  }
}

///|
/// 在等间距表上做线性插值取值。
fn interpolate_table(
  table : Array[Double],
  channel : Int32,
  entries : Int32,
  x : Double,
) -> Double {
  let base = channel * entries
  let v = clamp01(x)
  if entries <= 1 {
    return v
  }
  let pos = v * (entries - 1).to_double()
  let i = pos.to_int()
  if i >= entries - 1 {
    return table[base + entries - 1]
  } else {
    let frac = pos - i.to_double()
    table[base + i] * (1.0 - frac) + table[base + i + 1] * frac
  }
}

///|
/// **求值**：把输入值（0..1）变换为输出值（0..1）。
///
/// 顺序：输入表 → 矩阵（仅 3 输入通道时）→ CLUT 多线性插值 → 输出表。
pub fn Clut::evaluate(self : Clut, inputs : Array[Double]) -> Array[Double] {
  let ic = self.input_channels
  let oc = self.output_channels
  // 1. 输入表
  let stage : Array[Double] = []
  for i = 0; i < ic; i = i + 1 {
    let v = if i < inputs.length() { inputs[i] } else { 0.0 }
    stage.push(interpolate_table(self.input_tables, i, self.input_entries, v))
  }
  // 2. 矩阵（仅当输入通道数为 3；ICC 规定矩阵只作用于 3 通道）
  let after_matrix = if ic == 3 && self.matrix.length() == 9 {
    let x = clamp01(stage[0])
    let y = clamp01(stage[1])
    let z = clamp01(stage[2])
    [
      clamp01(self.matrix[0] * x + self.matrix[1] * y + self.matrix[2] * z),
      clamp01(self.matrix[3] * x + self.matrix[4] * y + self.matrix[5] * z),
      clamp01(self.matrix[6] * x + self.matrix[7] * y + self.matrix[8] * z),
    ]
  } else {
    stage
  }
  // 3. CLUT 多线性插值
  let lut_out = self.interpolate_clut(after_matrix)
  // 4. 输出表
  let out : Array[Double] = []
  for i = 0; i < oc; i = i + 1 {
    out.push(
      interpolate_table(self.output_tables, i, self.output_entries, lut_out[i]),
    )
  }
  out
}

///|
/// 在 CLUT 网点上做多线性插值。
///
/// 对每个输入维度计算 `位置 = v * (gc-1)`、取整索引与小数部分，
/// 然后遍历 `2^ic` 个角点，按小数部分组合权重。
/// 步长：最后一维变化最快（步长 1 个节点），依次向前乘 `gc`。
fn Clut::interpolate_clut(self : Clut, values : Array[Double]) -> Array[Double] {
  let ic = self.input_channels
  let oc = self.output_channels
  let gc = self.grid_points
  // 各维的基点与小数部分
  let base : Array[Int32] = []
  let frac : Array[Double] = []
  for i = 0; i < ic; i = i + 1 {
    let v = clamp01(values[i])
    let pos = v * (gc - 1).to_double()
    let mut b = pos.to_int()
    if b > gc - 2 {
      b = gc - 2
    }
    if b < 0 {
      b = 0
    }
    base.push(b)
    frac.push(pos - b.to_double())
  }
  // 各维步长（以节点为单位）
  let stride : Array[Int32] = []
  for i = 0; i < ic; i = i + 1 {
    let mut s = 1
    for j = i + 1; j < ic; j = j + 1 {
      s = s * gc
    }
    stride.push(s)
  }
  let out : Array[Double] = []
  for c = 0; c < oc; c = c + 1 {
    out.push(0.0)
  }
  // 遍历 2^ic 个角点
  let corners = 1 << ic
  for mask = 0; mask < corners; mask = mask + 1 {
    let mut weight = 1.0
    let mut node = 0
    for i = 0; i < ic; i = i + 1 {
      let bit = (mask >> i) & 1
      if bit == 1 {
        weight = weight * frac[i]
        node = node + (base[i] + 1) * stride[i]
      } else {
        weight = weight * (1.0 - frac[i])
        node = node + base[i] * stride[i]
      }
    }
    if weight != 0.0 {
      for c = 0; c < oc; c = c + 1 {
        out[c] = out[c] + weight * self.clut[node * oc + c]
      }
    }
  }
  out
}

///|
/// 把 CLUT 的输出（按位深满量程归一化到 [0,1]）解码为 PCS Lab。
///
/// **ICC v2 与 v4 的 Lab 编码范围不同**，这是实现 LUT 时最容易出错的地方：
///
/// | 版本 | 编码 | L 满量程 | a/b 满量程 |
/// |------|------|----------|-----------|
/// | v2 | 16 位 | `0xFF00` = 65280 | `0xFF00` |
/// | v2 | 8 位 | `0xFF` = 255 | `0xFF` |
/// | v4 | 16 位 | `0xFFFF` = 65535 | `0xFFFF` |
///
/// 因此需要同时知道**位深**与**版本**：8 位表值本身就是满量程，
/// 不需要乘回 65535；16 位表值要先乘回 65535 再按版本的上限折算。
///
/// 实测依据：本机 CMYK 打印机 profile（v2.0）的 A2B1 首个 CLUT 节点为
/// `(65533, 33024, 33022)`。按 v2 解码得 Lab ≈ (100.39, 1.00, 0.99)，
/// 与 lcms2 在 K=0 处的 (100.00, 0.00, 0.00) 吻合；按 v4 解码得
/// (100.00, 0.50, 0.49)，a/b 偏差明显更大。
pub fn clut_output_to_lab(
  values : Array[Double],
  bit_depth : Int32,
  is_v2 : Bool,
) -> Lab {
  // 只对**原始比例**做 [0,1] 夹紧（即限制在 0..满位深）。
  //
  // 注意不能在折算之后再夹到 1.0：v2 的 Lab 编码上限是 0xFF00，
  // 但 profile 里合法地存到 0xFFFF（表示略高于 100 的 L）。
  // 若在折算后夹紧，L=65533 这类值会被截成 100.0。
  // 本项目最初正是这样写的，网格节点判据立刻抓到了它
  // （期望 100.387561，实得 100）。
  let fraction = fn(v : Double) -> Double {
    let x = clamp01(v)
    if bit_depth == 8 {
      // 8 位表值直接就是该版本的上限
      x
    } else if is_v2 {
      // 16 位表值 0..65535，v2 的名义上限是 65280
      x * 65535.0 / 65280.0
    } else {
      x
    }
  }
  {
    l: fraction(values[0]) * 100.0,
    // a/b 编码：0..1 线性映射到 -128..127
    a: fraction(values[1]) * 255.0 - 128.0,
    b: fraction(values[2]) * 255.0 - 128.0,
  }
}

///|
/// 把 Lab 编码到 CLUT 输入域（`clut_output_to_lab` 的逆）。
pub fn lab_to_clut_input(
  lab : Lab,
  bit_depth : Int32,
  is_v2 : Bool,
) -> Array[Double] {
  let unscale = fn(f : Double) -> Double {
    if bit_depth == 8 {
      f
    } else if is_v2 {
      f * 65280.0 / 65535.0
    } else {
      f
    }
  }
  [
    unscale(clamp01(lab.l / 100.0)),
    unscale(clamp01((lab.a + 128.0) / 255.0)),
    unscale(clamp01((lab.b + 128.0) / 255.0)),
  ]
}

///|
/// 该 profile 是否使用 ICC v2 的 PCS 编码。
///
/// ICC 的版本从 2 直接跳到 4，没有 v3。因此主版本号 <= 2 即视为 v2。
/// 这个判断影响 Lab 的解码范围（见 `clut_output_to_lab`）。
pub fn Profile::is_v2(self : Profile) -> Bool {
  self.header.major_version <= 2
}

///|
/// 按渲染意图选取 **设备 → PCS** 的 LUT tag 签名。
///
/// ICC 的编号约定：
///
/// | 意图 | 编号 | tag |
/// |------|------|-----|
/// | 感知 | 0 | `A2B0` |
/// | 媒体相对比色 | 1 | `A2B1` |
/// | 饱和度 | 2 | `A2B2` |
/// | 绝对比色 | 3 | 无独立 tag，用 `A2B1` 再加白点调整 |
///
/// 实测依据：本机 CMYK 打印机 profile 的 A2B0 与 A2B1 **内容不同**
/// （逐字节比较有 26539 处差异，全部落在 CLUT 区）。用 lcms2 以 intent=1
/// 变换时只有 A2B1 的节点值与之一致——若误用 A2B0，暗端会差约 5 个 L 单位。
pub fn intent_to_a2b_tag(intent : Int32) -> String {
  match intent {
    0 => "A2B0"
    2 => "A2B2"
    // 相对比色与绝对比色都用 A2B1（绝对比色需另做白点调整，本库未实现）
    _ => "A2B1"
  }
}

///|
/// 按渲染意图选取 **PCS → 设备** 的 LUT tag 签名。
pub fn intent_to_b2a_tag(intent : Int32) -> String {
  match intent {
    0 => "B2A0"
    2 => "B2A2"
    _ => "B2A1"
  }
}

///|
/// 取出设备 → PCS 的 LUT。
///
/// 若指定意图的 tag 不存在，退回 `A2B0`；都没有则报错。
pub fn Profile::a2b(self : Profile, intent : Int32) -> Clut raise IccError {
  let want = intent_to_a2b_tag(intent)
  match self.find_tag(want) {
    Some(t) => parse_clut_tag(self.data, t)
    None =>
      match self.find_tag("A2B0") {
        Some(t) => parse_clut_tag(self.data, t)
        None =>
          raise BadTagData(
            tag=want,
            reason="profile 中既没有 \{want} 也没有 A2B0，无法做设备到 PCS 的 LUT 变换",
          )
      }
  }
}

///|
/// 取出 PCS → 设备的 LUT。
pub fn Profile::b2a(self : Profile, intent : Int32) -> Clut raise IccError {
  let want = intent_to_b2a_tag(intent)
  match self.find_tag(want) {
    Some(t) => parse_clut_tag(self.data, t)
    None =>
      match self.find_tag("B2A0") {
        Some(t) => parse_clut_tag(self.data, t)
        None =>
          raise BadTagData(
            tag=want,
            reason="profile 中既没有 \{want} 也没有 B2A0，无法做 PCS 到设备的 LUT 变换",
          )
      }
  }
}

///|
/// 设备值（0..1，按 profile 输入色空间的通道顺序）→ PCS Lab。
///
/// 这是 CLUT 型 profile 的 A2B 方向的完整求值：先在 CLUT 上求值，
/// 再按 profile 版本解码 Lab。
///
/// 仅支持 PCS 为 `Lab ` 的 profile。PCS 为 `XYZ ` 的 LUT 型 profile
/// 需要另一套解码（XYZ 的编码范围与 Lab 不同），当前版本显式报错，
/// 不静默给出错误颜色。
pub fn Profile::device_to_lab(
  self : Profile,
  intent : Int32,
  inputs : Array[Double],
) -> Lab raise IccError {
  if self.header.pcs != "Lab " {
    raise BadTagData(
      tag="pcs",
      reason="LUT 解码当前只支持 PCS 为 \"Lab \" 的 profile，实际 \"\{self.header.pcs}\"",
    )
  }
  let table = self.a2b(intent)
  let raw = table.evaluate(inputs)
  clut_output_to_lab(raw, table.bit_depth, self.is_v2())
}
