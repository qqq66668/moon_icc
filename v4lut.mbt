///|
/// ICC v4 的 `mAB ` / `mBA ` LUT（`lutAToBType` / `lutBToAType`）解析与求值。
///
/// `mft1`/`mft2`（v2 的 `lut8Type`/`lut16Type`）在 `clut.mbt` 实现，
/// 本文件只处理 v4 的这两种新类型。
///
/// ## tag 数据布局
///
/// | 偏移 | 大小 | 内容 |
/// |------|------|------|
/// | 0..3 | 4    | 类型签名 `mAB ` 或 `mBA ` |
/// | 4..7 | 4    | 保留 |
/// | 8    | 1    | 输入通道数 |
/// | 9    | 1    | 输出通道数 |
/// | 10..11 | 2  | 保留 |
/// | 12..31 | 20 | 5 个偏移：B、矩阵、M、CLUT、A（均相对 tag 起始） |
///
/// 五个偏移指向的段位于其后，顺序**不固定**（`mBA` 的书写顺序与 `mAB` 相反），
/// 必须按偏移寻址而不是按顺序读。
///
/// ## 与 `mft1`/`mft2` 的差别（实现时最容易踩的地方）
///
/// 1. **矩阵段没有类型签名头**。偏移直接指向 9 个 `s15Fixed16` 矩阵项，
///    紧随其后是 3 个 `s15Fixed16` 偏移项，共 48 字节。
///    本文件初次实现时按"先跳 8 字节类型头"读，结果把 M 段的 `para`
///    签名当成了矩阵偏移项，与参考实现的偏差最大达 10 级
///    （形如 28769.44 的"偏移"就是 `'para'` 四个字节被当成定点数）。
/// 2. **曲线段内嵌在 tag 里，没有长度字段**。类型签名后紧跟的 4 字节是
///    保留位而不是长度；段长度必须按类型从内容推算（见 `curve_segment_len`）。
///    对拍样本 `test4.icc` 的曲线段保留位恰为 0，若当成长度读会直接读错位。
/// 3. **曲线段要补齐到 4 字节边界**（相对文件绝对位置）。
///
/// ## 处理顺序
///
/// - `mAB `（设备 → PCS）：A 曲线 → CLUT → M 曲线 → 矩阵 → B 曲线
/// - `mBA `（PCS → 设备）：B 曲线 → 矩阵 → M 曲线 → CLUT → A 曲线
///
/// A/M/B 三段都可以缺省（偏移为 0），CLUT 也可以缺省；
/// 每条曲线的通道数由方向决定：`mAB` 的 A 用输入通道数、M/B 用输出通道数，
/// `mBA` 的 B/M 用输入通道数、A 用输出通道数。这与 lcms2 的读取代码一致。
///
/// ## 插值方式
///
/// 参考实现在两个方向用的插值**不同**，本文件照此实现并已用对拍验证：
///
/// - `mAB `（设备作索引）用**四面体**插值；
/// - `mBA `（PCS Lab 作索引）用**三线性**插值。
///
/// 依据：lcms2 `cmsintrp.c` 对 3 输入 CLUT 默认选四面体，
/// 而 `cmsio1.c` 的 `_cmsReadOutputLUT` 在 PCS 为 Lab 时会显式改回三线性
/// （代码注释称这是"controversial stuff"）。用实测数据验证：
/// 把 `mAB ` 换成三线性、或把 `mBA ` 换成四面体，与参考实现的一致率都会下降。

///|
/// v4 LUT 的方向。
pub enum V4LutKind {
  /// `mAB `：设备 → PCS。
  AToB
  /// `mBA `：PCS → 设备。
  BToA
}

///|
/// 一个已解析的 `mAB ` / `mBA ` LUT。
pub struct V4Lut {
  /// 方向，决定各段的处理顺序与曲线通道数。
  kind : V4LutKind
  /// 输入通道数。
  input_channels : Int32
  /// 输出通道数。
  output_channels : Int32
  /// A 曲线（可为空数组表示缺省）。
  a_curves : Array[ToneCurve]
  /// M 曲线（可为空数组表示缺省）。
  m_curves : Array[ToneCurve]
  /// B 曲线（可为空数组表示缺省）。
  b_curves : Array[ToneCurve]
  /// 3×3 矩阵（行主序 9 项）；空数组表示缺省。
  matrix : Array[Double]
  /// 矩阵的 3 个偏移项；无矩阵时为空。
  offsets : Array[Double]
  /// 每一维的网格点数；空数组表示缺省 CLUT。
  grid : Array[Int32]
  /// CLUT 表值的位深：1（u8）或 2（u16）；无 CLUT 时为 0。
  precision : Int32
  /// CLUT 节点值，按 (输入格点组合, 输出通道) 连续存放，归一化到 [0,1]。
  clut : Array[Double]
}

///|
/// 解析 `mAB ` / `mBA ` tag。
pub fn parse_v4_lut(
  data : Bytes,
  entry : IccTagEntry,
  kind : V4LutKind,
) -> V4Lut raise IccError {
  let (type_sig, body_at) = tag_type_and_data(data, entry)
  let want = match kind {
    AToB => "mAB "
    BToA => "mBA "
  }
  if type_sig != want {
    raise BadTagData(
      tag=entry.signature,
      reason="期望类型 \"\{want}\"，实际 \"\{type_sig}\"",
    )
  }
  let base = entry.offset
  let tag_end = entry.offset + entry.size
  let r = BigEndianReader::new(data)
  r.seek(body_at)
  let input_channels = r.read_u8()
  let output_channels = r.read_u8()
  r.skip(2)
  let off_b = r.read_u32()
  let off_mat = r.read_u32()
  let off_m = r.read_u32()
  let off_c = r.read_u32()
  let off_a = r.read_u32()
  if input_channels < 1 ||
    output_channels < 1 ||
    input_channels > 15 ||
    output_channels > 15 {
    raise BadTagData(
      tag=entry.signature,
      reason="通道数非法: 输入 \{input_channels} 输出 \{output_channels}",
    )
  }
  // 曲线段：条数由方向决定
  let (a_count, m_count, b_count) = match kind {
    AToB => (input_channels, output_channels, output_channels)
    BToA => (output_channels, input_channels, input_channels)
  }
  // 偏移必须落在 tag 范围内
  let offs : Array[Int32] = [off_b, off_mat, off_m, off_c, off_a]
  for i = 0; i < offs.length(); i = i + 1 {
    let o = offs[i]
    if o != 0 && (o < 24 || base + o >= tag_end) {
      raise BadTagData(
        tag=entry.signature,
        reason="第 \{i} 个段偏移 \{o} 超出 tag 范围（长度 \{entry.size}）",
      )
    }
  }
  let a_curves = read_curve_set(data, entry, off_a, a_count)
  let m_curves = read_curve_set(data, entry, off_m, m_count)
  let b_curves = read_curve_set(data, entry, off_b, b_count)
  // 矩阵段（无类型签名头）
  let matrix : Array[Double] = []
  let offsets : Array[Double] = []
  if off_mat != 0 {
    if base + off_mat + 48 > tag_end {
      raise BadTagData(
        tag=entry.signature,
        reason="矩阵段越界（偏移 \{off_mat}，需要 48 字节）",
      )
    }
    let mr = BigEndianReader::new(data)
    mr.seek(base + off_mat)
    for i = 0; i < 9; i = i + 1 {
      matrix.push(mr.read_s15f16())
    }
    for i = 0; i < 3; i = i + 1 {
      offsets.push(mr.read_s15f16())
    }
  }
  // CLUT 段
  let grid : Array[Int32] = []
  let clut : Array[Double] = []
  let mut precision = 0
  if off_c != 0 {
    let cr = BigEndianReader::new(data)
    cr.seek(base + off_c)
    for i = 0; i < 16; i = i + 1 {
      let g = cr.read_u8()
      if i < input_channels {
        if g < 2 {
          raise BadTagData(
            tag=entry.signature,
            reason="CLUT 第 \{i} 维网格点数 \{g} 小于 2，无法插值",
          )
        }
        grid.push(g)
      }
    }
    precision = cr.read_u8()
    cr.skip(3)
    if precision != 1 && precision != 2 {
      raise BadTagData(
        tag=entry.signature,
        reason="CLUT 表值位深 \{precision} 字节非法（仅支持 1 或 2）",
      )
    }
    // 节点数：profile 是外部不可信输入，先算并设上限，避免畸形值导致巨量分配
    let mut nodes_per_output = 1
    for i = 0; i < input_channels; i = i + 1 {
      nodes_per_output = nodes_per_output * grid[i]
      if nodes_per_output > 1_000_000 {
        raise BadTagData(
          tag=entry.signature,
          reason="CLUT 节点数超过上限，疑似畸形 profile",
        )
      }
    }
    let count = nodes_per_output * output_channels
    for i = 0; i < count; i = i + 1 {
      clut.push(
        if precision == 1 {
          cr.read_u8().to_double() / 255.0
        } else {
          cr.read_u16().to_double() / 65535.0
        },
      )
    }
  }
  {
    kind,
    input_channels,
    output_channels,
    a_curves,
    m_curves,
    b_curves,
    matrix,
    offsets,
    grid,
    precision,
    clut,
  }
}

///|
/// 读一组内嵌曲线。
///
/// `off` 为相对 tag 起始的偏移，0 表示缺省。曲线段没有长度字段，
/// 每条曲线的长度由 `curve_segment_len` 从内容推算，再补齐到 4 字节边界。
fn read_curve_set(
  data : Bytes,
  entry : IccTagEntry,
  off : Int32,
  count : Int32,
) -> Array[ToneCurve] raise IccError {
  let out : Array[ToneCurve] = []
  if off == 0 {
    return out
  }
  let base = entry.offset
  let tag_end = entry.offset + entry.size
  let mut p = base + off
  for i = 0; i < count; i = i + 1 {
    if p + 8 > tag_end {
      raise BadTagData(
        tag=entry.signature,
        reason="曲线段第 \{i} 条越界（偏移 \{p - base}）",
      )
    }
    let sub : IccTagEntry = {
      signature: entry.signature,
      offset: p,
      size: tag_end - p,
    }
    out.push(parse_tone_curve(data, sub))
    let len = curve_segment_len(data, p, entry.signature)
    p = p + len
    // 补齐到 4 字节边界（相对文件绝对位置，与 lcms2 的 _cmsReadAlignment 一致）
    p = (p + 3) / 4 * 4
  }
  out
}

///|
/// 算出一条内嵌曲线的总长度（含 8 字节类型头，不含对齐补齐）。
///
/// 曲线段**没有长度字段**：类型签名之后的 4 字节是保留位。
/// 因此只能按类型从内容推算：
///
/// | 类型 | 内容 |
/// |------|------|
/// | `curv` 项数 0 | 8 + 4 |
/// | `curv` 项数 1 | 8 + 4 + 2（单个 gamma） |
/// | `curv` 项数 n>1 | 8 + 4 + 2n |
/// | `para` | 8 + 4 + 4×参数个数（1/3/4/5/7） |
fn curve_segment_len(
  data : Bytes,
  at : Int32,
  tag : String,
) -> Int32 raise IccError {
  let r = BigEndianReader::new(data)
  r.seek(at)
  let sig = r.read_signature()
  r.skip(4)
  match sig {
    "curv" => {
      let count = r.read_u32()
      if count < 0 {
        raise BadTagData(tag~, reason="curv 项数非法")
      }
      if count == 0 {
        12
      } else if count == 1 {
        14
      } else {
        12 + count * 2
      }
    }
    "para" => {
      let ft = r.read_u16()
      r.skip(2)
      let n = match ft {
        0 => 1
        1 => 3
        2 => 4
        3 => 5
        4 => 7
        _ =>
          raise BadTagData(tag~, reason="不支持的 para 函数类型 \{ft}")
      }
      12 + n * 4
    }
    _ =>
      raise BadTagData(
        tag~,
        reason="内嵌曲线类型 \"\{sig}\" 不支持（仅 curv 与 para）",
      )
  }
}

///|
/// 对一组曲线求值：通道数不足时按恒等补齐，结果夹到 [0,1]。
///
/// 夹紧是必要的：lcms2 的 16 位定点管线在每一级之后都把值限制在
/// [0,65535]。实测 `mBA` 的 M 曲线在超色域输入下会算出负值，
/// 不夹紧会与参考实现出现数十级的偏差。
///
/// **曲线集缺省（长度为 0）时必须原样透传**，不能返回空数组——
/// `mAB `/`mBA ` 的 A/M/B 三段都可以缺省，中间某一级缺省时若把数组清空，
/// 后续阶段就拿不到通道值（本项目真实踩到：一个只有 A 曲线 + CLUT 的
/// 合成 profile 在最大输入处整体输出 0）。
fn apply_curve_set(
  curves : Array[ToneCurve],
  values : Array[Double],
) -> Array[Double] {
  let out : Array[Double] = []
  if curves.length() == 0 {
    for v in values {
      out.push(v)
    }
    return out
  }
  for i = 0; i < curves.length(); i = i + 1 {
    let v = if i < values.length() { values[i] } else { 0.0 }
    out.push(clamp01(curves[i].evaluate(v)))
  }
  out
}

///|
/// 对 mAB/mBA 的 LUT 求值。
///
/// 输入按该方向的入口通道数给出（`mAB ` 为设备值，`mBA ` 为 PCS Lab 编码），
/// 输出按出口通道数给出，全部归一化到 [0,1]。
pub fn V4Lut::evaluate(self : V4Lut, inputs : Array[Double]) -> Array[Double] {
  match self.kind {
    AToB => {
      let x = apply_curve_set(self.a_curves, inputs)
      let y = if self.clut.length() > 0 {
        self.interpolate_clut(x, true)
      } else {
        x
      }
      let y = apply_curve_set(self.m_curves, y)
      let y = self.apply_matrix(y)
      apply_curve_set(self.b_curves, y)
    }
    BToA => {
      let y = apply_curve_set(self.b_curves, inputs)
      let y = self.apply_matrix(y)
      let y = apply_curve_set(self.m_curves, y)
      let x = if self.clut.length() > 0 {
        self.interpolate_clut(y, false)
      } else {
        y
      }
      apply_curve_set(self.a_curves, x)
    }
  }
}

///|
/// 应用矩阵与偏移项（仅 3 通道；缺省时原样返回）。
fn V4Lut::apply_matrix(self : V4Lut, values : Array[Double]) -> Array[Double] {
  if self.matrix.length() != 9 || values.length() < 3 {
    return values
  }
  let x = clamp01(values[0])
  let y = clamp01(values[1])
  let z = clamp01(values[2])
  [
    clamp01(
      self.matrix[0] * x +
      self.matrix[1] * y +
      self.matrix[2] * z +
      self.offsets[0],
    ),
    clamp01(
      self.matrix[3] * x +
      self.matrix[4] * y +
      self.matrix[5] * z +
      self.offsets[1],
    ),
    clamp01(
      self.matrix[6] * x +
      self.matrix[7] * y +
      self.matrix[8] * z +
      self.offsets[2],
    ),
  ]
}

///|
/// 在 CLUT 上插值。`tetrahedral` 为真时用四面体（仅 3 输入），否则用三线性。
fn V4Lut::interpolate_clut(
  self : V4Lut,
  values : Array[Double],
  tetrahedral : Bool,
) -> Array[Double] {
  let ic = self.input_channels
  let oc = self.output_channels
  // 各维基点、小数部分与步长（单位：表项）
  let base : Array[Int32] = []
  let frac : Array[Double] = []
  let stride : Array[Int32] = []
  for i = 0; i < ic; i = i + 1 {
    let g = self.grid[i]
    let v = clamp01(if i < values.length() { values[i] } else { 0.0 })
    let pos = v * (g - 1).to_double()
    let mut b = pos.to_int()
    if b > g - 2 {
      b = g - 2
    }
    if b < 0 {
      b = 0
    }
    base.push(b)
    frac.push(pos - b.to_double())
    let mut s = oc
    for j = i + 1; j < ic; j = j + 1 {
      s = s * self.grid[j]
    }
    stride.push(s)
  }
  if tetrahedral && ic == 3 {
    return self.tetrahedral(base, frac, stride)
  }
  let out : Array[Double] = []
  for c = 0; c < oc; c = c + 1 {
    out.push(0.0)
  }
  let corners = 1 << ic
  for mask = 0; mask < corners; mask = mask + 1 {
    let mut weight = 1.0
    let mut node = 0
    for i = 0; i < ic; i = i + 1 {
      if ((mask >> i) & 1) == 1 {
        weight = weight * frac[i]
        node = node + (base[i] + 1) * stride[i]
      } else {
        weight = weight * (1.0 - frac[i])
        node = node + base[i] * stride[i]
      }
    }
    if weight != 0.0 {
      for c = 0; c < oc; c = c + 1 {
        out[c] = out[c] + weight * self.clut[node + c]
      }
    }
  }
  out
}

///|
/// 3 维 CLUT 的四面体（Sakamoto）插值。
///
/// 与 lcms2 `cmsintrp.c` 的 `TetrahedralInterpFloat` 同构：
/// 按 `rx/ry/rz` 的大小关系选六个四面体之一，用 4 个角点做线性组合。
/// 注意输入恰为 1 时该维"不进位"（`X1 = X0`），这一细节处理错会让
/// 白色点差出十几级。
fn V4Lut::tetrahedral(
  self : V4Lut,
  base : Array[Int32],
  frac : Array[Double],
  stride : Array[Int32],
) -> Array[Double] {
  let oc = self.output_channels
  let x0 = base[0]
  let y0 = base[1]
  let z0 = base[2]
  let rx = frac[0]
  let ry = frac[1]
  let rz = frac[2]
  let x1 = x0 + 1
  let y1 = y0 + 1
  let z1 = z0 + 1
  let sx = stride[0]
  let sy = stride[1]
  let sz = stride[2]
  let cell = fn(x : Int32, y : Int32, z : Int32, c : Int32) -> Double {
    self.clut[x * sx + y * sy + z * sz + c]
  }
  let c0 : Array[Double] = []
  for c = 0; c < oc; c = c + 1 {
    c0.push(cell(x0, y0, z0, c))
  }
  // 六个四面体按 (rx,ry,rz) 的大小关系选择
  let out : Array[Double] = []
  for c = 0; c < oc; c = c + 1 {
    let mut v1 = 0.0
    let mut v2 = 0.0
    let mut v3 = 0.0
    if rx >= ry && ry >= rz {
      v1 = cell(x1, y0, z0, c) - c0[c]
      v2 = cell(x1, y1, z0, c) - cell(x1, y0, z0, c)
      v3 = cell(x1, y1, z1, c) - cell(x1, y1, z0, c)
    } else if rx >= rz && rz >= ry {
      v1 = cell(x1, y0, z0, c) - c0[c]
      v2 = cell(x1, y1, z1, c) - cell(x1, y0, z1, c)
      v3 = cell(x1, y0, z1, c) - cell(x1, y0, z0, c)
    } else if rz >= rx && rx >= ry {
      v1 = cell(x1, y0, z1, c) - cell(x0, y0, z1, c)
      v2 = cell(x1, y1, z1, c) - cell(x1, y0, z1, c)
      v3 = cell(x0, y0, z1, c) - c0[c]
    } else if ry >= rx && rx >= rz {
      v1 = cell(x1, y1, z0, c) - cell(x0, y1, z0, c)
      v2 = cell(x0, y1, z0, c) - c0[c]
      v3 = cell(x1, y1, z1, c) - cell(x1, y1, z0, c)
    } else if ry >= rz && rz >= rx {
      v1 = cell(x1, y1, z1, c) - cell(x0, y1, z1, c)
      v2 = cell(x0, y1, z0, c) - c0[c]
      v3 = cell(x0, y1, z1, c) - cell(x0, y1, z0, c)
    } else {
      v1 = cell(x1, y1, z1, c) - cell(x0, y1, z1, c)
      v2 = cell(x0, y1, z1, c) - cell(x0, y0, z1, c)
      v3 = cell(x0, y0, z1, c) - c0[c]
    }
    out.push(clamp01(c0[c] + v1 * rx + v2 * ry + v3 * rz))
  }
  out
}

///|
/// LUT 型 tag 的统一入口。
///
/// v2 的 `mft1`/`mft2` 与 v4 的 `mAB `/`mBA ` 数据布局差别很大，
/// 但对外语义相同："一组归一化输入 → 一组归一化输出"。
/// 统一成一个枚举后，链接逻辑（`transform.mbt`）不必区分二者。
pub enum LutTable {
  /// v2 的 `mft1`（8 位表值）或 `mft2`（16 位表值）。
  LutV2(Clut)
  /// v4 的 `mAB ` / `mBA `。
  LutV4(V4Lut)
}

///|
/// 解析**设备 → PCS** 方向的 LUT tag。
pub fn parse_a2b_table(
  data : Bytes,
  entry : IccTagEntry,
) -> LutTable raise IccError {
  let (type_sig, _) = tag_type_and_data(data, entry)
  if type_sig == "mft1" || type_sig == "mft2" {
    return LutV2(parse_clut_tag(data, entry))
  }
  if type_sig == "mAB " {
    return LutV4(parse_v4_lut(data, entry, AToB))
  }
  raise BadTagData(
    tag=entry.signature,
    reason="A2B 方向的 LUT 类型 \"\{type_sig}\" 不支持（仅 mft1 / mft2 / \"mAB \"）",
  )
}

///|
/// 解析**PCS → 设备** 方向的 LUT tag。
pub fn parse_b2a_table(
  data : Bytes,
  entry : IccTagEntry,
) -> LutTable raise IccError {
  let (type_sig, _) = tag_type_and_data(data, entry)
  if type_sig == "mft1" || type_sig == "mft2" {
    return LutV2(parse_clut_tag(data, entry))
  }
  if type_sig == "mBA " {
    return LutV4(parse_v4_lut(data, entry, BToA))
  }
  raise BadTagData(
    tag=entry.signature,
    reason="B2A 方向的 LUT 类型 \"\{type_sig}\" 不支持（仅 mft1 / mft2 / \"mBA \"）",
  )
}

///|
/// 求值。
pub fn LutTable::evaluate(
  self : LutTable,
  inputs : Array[Double],
) -> Array[Double] {
  match self {
    LutV2(c) => c.evaluate(inputs)
    LutV4(v) => v.evaluate(inputs)
  }
}

///|
/// LUT 的类型签名（诊断输出用）。
pub fn LutTable::type_name(self : LutTable) -> String {
  match self {
    LutV2(c) => if c.bit_depth == 8 { "mft1" } else { "mft2" }
    LutV4(v) =>
      match v.kind {
        AToB => "mAB "
        BToA => "mBA "
      }
  }
}

///|
/// 网格点数描述。
///
/// `mft1`/`mft2` 每一维的网格点数相同，只报一个值；
/// `mAB `/`mBA ` 每一维可以不同，逐维列出。
pub fn LutTable::grid_text(self : LutTable) -> String {
  match self {
    LutV2(c) => "\{c.grid_points}"
    LutV4(v) =>
      if v.grid.length() == 0 {
        "无 CLUT"
      } else {
        let b = StringBuilder()
        for i = 0; i < v.grid.length(); i = i + 1 {
          if i > 0 {
            b.write_char('x')
          }
          b.write_string(v.grid[i].to_string())
        }
        b.to_string()
      }
  }
}

///|
/// 输入通道数。
pub fn LutTable::input_channels(self : LutTable) -> Int32 {
  match self {
    LutV2(c) => c.input_channels
    LutV4(v) => v.input_channels
  }
}

///|
/// 输出通道数。
pub fn LutTable::output_channels(self : LutTable) -> Int32 {
  match self {
    LutV2(c) => c.output_channels
    LutV4(v) => v.output_channels
  }
}

///|
/// 表值位深（`clut_output_to_lab` / `clut_output_to_xyz` 需要）。
///
/// v2 的 `mft1`/`mft2` 由类型决定（8 / 16 位）；
/// v4 的 `mAB `/`mBA ` 由 CLUT 段的精度字节决定（1 字节 → 8 位，2 字节 → 16 位），
/// 因为这个位深同时决定 **XYZ PCS 的折算系数**（8 位满量程是 128，16 位是 32768）。
pub fn LutTable::bit_depth(self : LutTable) -> Int32 {
  match self {
    LutV2(c) => c.bit_depth
    LutV4(v) => if v.precision == 1 { 8 } else { 16 }
  }
}

///|
/// 该表给出的 PCS Lab 是否按 **v2 编码** 解释。
///
/// `mft1`/`mft2` 用 profile 版本判定（v2 的上限是 0xFF00）；
/// `mAB `/`mBA ` 是 v4 独有的类型，一律是 v4 口径。
pub fn LutTable::pcs_is_v2(self : LutTable, profile_is_v2 : Bool) -> Bool {
  match self {
    LutV2(_) => profile_is_v2
    LutV4(_) => false
  }
}
