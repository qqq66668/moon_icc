///|
/// ICC tag 数据体的解析。
///
/// 每个 tag 数据以 4 字节类型签名开头，紧接着 4 字节保留位，之后是类型相关内容。
/// 本模块只实现 matrix/TRC 变换所需的类型：
///
/// - `XYZ `：三刺激值（matrix 列、白点、黑点）
/// - `curv`：一维曲线（用查找表或单一 gamma 值表示）
/// - `para`：参数化曲线（sRGB 等常用曲线，用 1..4 个参数表示）
///
/// 其余类型（`mft1`/`mft2`/`mAB`/`mBA`/`text` 等）不在本模块范围，
/// 由调用方按需处理；命名色（`ncl2`）的解析在 `named_color.mbt`。

///|
/// tag 类型签名与数据体之间固定有 4 字节保留位。
let tag_type_header_size : Int32 = 8

///|
/// 解析 tag 数据体的公共前置：返回 (类型签名, 数据体起始偏移)。
pub fn tag_type_and_data(
  data : Bytes,
  entry : IccTagEntry,
) -> (String, Int32) raise IccError {
  if entry.size < tag_type_header_size {
    raise BadTagData(
      tag=entry.signature,
      reason="tag 数据不足 \{tag_type_header_size} 字节，无法容纳类型签名",
    )
  }
  let r = BigEndianReader::new(data)
  r.seek(entry.offset)
  let signature = r.read_signature()
  // 跳过 4 字节保留位
  r.skip(4)
  (signature, r.position())
}

///|
/// 解析 `XYZ ` 类型 tag，返回三刺激值。
///
/// 数据体为 3 个 `s15Fixed16Number`。用于 `rXYZ`/`gXYZ`/`bXYZ`/`wtpt`/`bkpt`。
pub fn parse_xyz_tag(
  data : Bytes,
  entry : IccTagEntry,
) -> XyzNumber raise IccError {
  let (type_sig, body_at) = tag_type_and_data(data, entry)
  if type_sig != "XYZ " {
    raise BadTagData(
      tag=entry.signature,
      reason="期望类型 \"XYZ \"，实际 \"\{type_sig}\"",
    )
  }
  let r = BigEndianReader::new(data)
  r.seek(body_at)
  let x = r.read_s15f16()
  let y = r.read_s15f16()
  let z = r.read_s15f16()
  { x, y, z, }
}

///|
/// 一维曲线（TRC）。
///
/// ICC 用两种方式表示：`curv` 类型（gamma 值或查找表）与 `para` 类型（参数方程）。
/// 本库统一求值为 `evaluate`。
pub enum ToneCurve {
  /// 单一 gamma 值：`y = x^gamma`。
  Gamma(Double)
  /// 查找表：在表项间线性插值，输入域 [0,1]。
  Table(Array[Double])
  /// 参数化曲线（`para` 类型），参数个数 1..4。
  Parametric(Array[Double])
}

///|
/// 解析 `curv` 类型 tag。
///
/// 数据体：u32 表项数 N，随后 N 个 u16（0..65535 映射到 [0,1]）。
/// N == 0 表示恒等曲线；N == 1 表示 `y = x^(值/256)`。
pub fn parse_curv_tag(
  data : Bytes,
  entry : IccTagEntry,
) -> ToneCurve raise IccError {
  let (type_sig, body_at) = tag_type_and_data(data, entry)
  if type_sig != "curv" {
    raise BadTagData(
      tag=entry.signature,
      reason="期望类型 \"curv\"，实际 \"\{type_sig}\"",
    )
  }
  let r = BigEndianReader::new(data)
  r.seek(body_at)
  let count = r.read_u32()
  match count {
    0 => ToneCurve::Table([])
    1 => {
      let raw = r.read_u16()
      ToneCurve::Gamma(raw.to_double() / 256.0)
    }
    _ => {
      // 表项是 u16，需要 2*count 字节
      if r.remaining() < count * 2 {
        raise BadTagData(
          tag=entry.signature,
          reason="曲线声明 \{count} 项，但剩余字节不足",
        )
      }
      let table : Array[Double] = []
      for i = 0; i < count; i = i + 1 {
        table.push(r.read_u16().to_double() / 65535.0)
      }
      ToneCurve::Table(table)
    }
  }
}

///|
/// 解析 `para` 类型 tag。
///
/// 数据体：u16 函数类型 (0..4)，u16 保留位，随后 s15Fixed16 参数。
/// 参数个数由函数类型决定：0→1 个, 1→3 个, 2→4 个, 3→5 个, 4→7 个。
pub fn parse_para_tag(
  data : Bytes,
  entry : IccTagEntry,
) -> ToneCurve raise IccError {
  let (type_sig, body_at) = tag_type_and_data(data, entry)
  if type_sig != "para" {
    raise BadTagData(
      tag=entry.signature,
      reason="期望类型 \"para\"，实际 \"\{type_sig}\"",
    )
  }
  let r = BigEndianReader::new(data)
  r.seek(body_at)
  let function_type = r.read_u16()
  r.skip(2)
  let param_count = match function_type {
    0 => 1
    1 => 3
    2 => 4
    3 => 5
    4 => 7
    _ =>
      raise BadTagData(
        tag=entry.signature,
        reason="不支持的 para 函数类型 \{function_type}",
      )
  }
  let params : Array[Double] = []
  for i = 0; i < param_count; i = i + 1 {
    params.push(r.read_s15f16())
  }
  ToneCurve::Parametric(params)
}

///|
/// 按 tag 类型自动分派解析曲线（`curv` 或 `para`）。
pub fn parse_tone_curve(
  data : Bytes,
  entry : IccTagEntry,
) -> ToneCurve raise IccError {
  let (type_sig, _) = tag_type_and_data(data, entry)
  match type_sig {
    "curv" => parse_curv_tag(data, entry)
    "para" => parse_para_tag(data, entry)
    _ =>
      raise BadTagData(
        tag=entry.signature,
        reason="不支持的曲线类型 \"\{type_sig}\"（仅支持 curv 与 para）",
      )
  }
}

///|
/// 把输入限制在 [0,1]。
fn clamp01(x : Double) -> Double {
  if x < 0.0 {
    0.0
  } else if x > 1.0 {
    1.0
  } else {
    x
  }
}

///|
/// 对曲线求值。
///
/// - `Gamma(g)`：`x^g`；
/// - `Table(t)`：在表项间线性插值，表长 1 时视为常量；
/// - `Parametric(p)`：按 ICC 定义的 5 种函数求值。
pub fn ToneCurve::evaluate(self : ToneCurve, x : Double) -> Double {
  let v = clamp01(x)
  match self {
    Gamma(g) => if g == 1.0 { v } else { @math.pow(v, g) }
    Table(t) => {
      let n = t.length()
      if n == 0 {
        // 空表表示恒等
        v
      } else if n == 1 {
        t[0]
      } else {
        // 均匀采样：索引 = v * (n-1)，在相邻项间线性插值
        let pos = v * (n - 1).to_double()
        let i = pos.to_int()
        if i >= n - 1 {
          t[n - 1]
        } else {
          let frac = pos - i.to_double()
          t[i] * (1.0 - frac) + t[i + 1] * frac
        }
      }
    }
    Parametric(p) => evaluate_parametric(p, v)
  }
}

///|
/// 按 ICC.1 表 68 求值参数化曲线。
///
/// 参数含义：`g` gamma、`a`、`b`、`c`、`d`、`e`、`f`，断点为 `x = d` 或 `x = -b/a`。
fn evaluate_parametric(p : Array[Double], x : Double) -> Double {
  let n = p.length()
  if n == 0 {
    return x
  }
  let g = p[0]
  match n {
    1 => @math.pow(x, g)
    3 => {
      // Y = (aX + b)^g  for X >= -b/a
      // Y = 0           for X <  -b/a
      let a = p[1]
      let b = p[2]
      let breakpoint = if a == 0.0 { 0.0 } else { -b / a }
      if x >= breakpoint {
        @math.pow(a * x + b, g)
      } else {
        0.0
      }
    }
    4 => {
      // Y = (aX + b)^g  for X >= -b/a
      // Y = cX          for X <  -b/a
      let a = p[1]
      let b = p[2]
      let c = p[3]
      let breakpoint = if a == 0.0 { 0.0 } else { -b / a }
      if x >= breakpoint {
        @math.pow(a * x + b, g)
      } else {
        c * x
      }
    }
    5 => {
      // Y = (aX + b)^g + e  for X >= d
      // Y = cX + f          for X <  d
      // 该形式只给了 e 与 f 中的 e（参数为 g,a,b,c,d,e）；f 取 0。
      let a = p[1]
      let b = p[2]
      let c = p[3]
      let d = p[4]
      if x >= d {
        @math.pow(a * x + b, g) + p[5]
      } else {
        c * x
      }
    }
    7 => {
      // Y = (aX + b)^g + e  for X >= d
      // Y = cX + f          for X <  d
      let a = p[1]
      let b = p[2]
      let c = p[3]
      let d = p[4]
      let e = p[5]
      let f = p[6]
      if x >= d {
        @math.pow(a * x + b, g) + e
      } else {
        c * x + f
      }
    }
    _ => x
  }
}
