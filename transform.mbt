///|
/// matrix/TRC 类型的色空间变换，以及 PCS 空间之间的转换。
///
/// ## 变换顺序（关键）
///
/// sRGB → PCS 必须**先对每个通道应用 TRC 做线性化，再乘矩阵**：
///
///     linear = TRC(encoded)
///     XYZ    = M · linear
///
/// 顺序反了的话，白点 (1,1,1) 与黑点 (0,0,0) **仍然是对的**，
/// 只有中间调全错。因此判据必须包含中间调样本，只测黑白点发现不了。
///
/// ## 白点与色适应
///
/// ICC 的 PCS 固定为 **D50**。sRGB profile 的 `rXYZ/gXYZ/bXYZ` 矩阵列
/// **已经**是从 sRGB 原生白点（D65）经 Bradford 适应到 D50 之后的结果，
/// 所以本模块**不再**做任何色适应——自行再加一次会让整体偏移。
/// 头部 `illuminant` 字段同样记录 D50，仅作参考，不参与变换。

///|
/// 3×3 矩阵，按列存储（ICC 中 `rXYZ`/`gXYZ`/`bXYZ` 各是一列）。
pub struct Matrix3 {
  /// 第一列（红通道的 XYZ）。
  col0 : XyzNumber
  /// 第二列（绿通道的 XYZ）。
  col1 : XyzNumber
  /// 第三列（蓝通道的 XYZ）。
  col2 : XyzNumber
}

///|
/// 用三列构造矩阵。
pub fn Matrix3::new(
  col0 : XyzNumber,
  col1 : XyzNumber,
  col2 : XyzNumber,
) -> Matrix3 {
  { col0, col1, col2, }
}

///|
/// 矩阵乘以列向量。
pub fn Matrix3::mul(self : Matrix3, v : XyzNumber) -> XyzNumber {
  {
    x: self.col0.x * v.x + self.col1.x * v.y + self.col2.x * v.z,
    y: self.col0.y * v.x + self.col1.y * v.y + self.col2.y * v.z,
    z: self.col0.z * v.x + self.col1.z * v.y + self.col2.z * v.z,
  }
}

///|
/// matrix/TRC 型 profile 的变换上下文。
///
/// 由 `Profile::matrix_trc` 构造，持有三列矩阵与三条通道曲线。
pub struct MatrixTrcTransform {
  /// 矩阵列。
  matrix : Matrix3
  /// 红通道曲线。
  trc_r : ToneCurve
  /// 绿通道曲线。
  trc_g : ToneCurve
  /// 蓝通道曲线。
  trc_b : ToneCurve
  /// profile 声明的白点（`wtpt`），仅作信息保留。
  white_point : XyzNumber
}

///|
/// 一个已解析的 ICC profile：头部 + tag 表，可按签名查找 tag。
pub struct Profile {
  /// 头部。
  header : IccHeader
  /// tag 表（保持文件原始顺序）。
  tags : Array[IccTagEntry]
  /// 原始字节，供 tag 数据解析使用。
  data : Bytes
}

///|
/// 解析完整 profile（头部 + tag 表）。
pub fn Profile::parse(data : Bytes) -> Profile raise IccError {
  let header = parse_header(data)
  let tags = parse_tag_table(data, header)
  { header, tags, data, }
}

///|
/// 按签名查找第一个匹配的 tag。
pub fn Profile::find_tag(self : Profile, signature : String) -> IccTagEntry? {
  for t in self.tags {
    if t.signature == signature {
      return Some(t)
    }
  }
  None
}

///|
/// 取 tag，缺失则报 `BadTagData`。
fn Profile::require_tag(
  self : Profile,
  signature : String,
) -> IccTagEntry raise IccError {
  match self.find_tag(signature) {
    Some(t) => t
    None =>
      raise BadTagData(
        tag=signature,
        reason="profile 中缺少该 tag，无法进行 matrix/TRC 变换",
      )
  }
}

///|
/// 构造 matrix/TRC 变换。
///
/// 需要 `rXYZ`/`gXYZ`/`bXYZ`/`rTRC`/`gTRC`/`bTRC` 六个 tag。
/// LUT 型 profile（打印机 CMYK 等）没有这些 tag，会报 `BadTagData`——
/// 这是**有意的显式失败**，而不是静默给出错误颜色。
pub fn Profile::matrix_trc(self : Profile) -> MatrixTrcTransform raise IccError {
  let r_xyz = parse_xyz_tag(self.data, self.require_tag("rXYZ"))
  let g_xyz = parse_xyz_tag(self.data, self.require_tag("gXYZ"))
  let b_xyz = parse_xyz_tag(self.data, self.require_tag("bXYZ"))
  let trc_r = parse_tone_curve(self.data, self.require_tag("rTRC"))
  let trc_g = parse_tone_curve(self.data, self.require_tag("gTRC"))
  let trc_b = parse_tone_curve(self.data, self.require_tag("bTRC"))
  let white_point = match self.find_tag("wtpt") {
    Some(t) => parse_xyz_tag(self.data, t)
    None => XyzNumber::{ x: 0.0, y: 0.0, z: 0.0, }
  }
  {
    matrix: Matrix3::new(r_xyz, g_xyz, b_xyz),
    trc_r,
    trc_g,
    trc_b,
    white_point,
  }
}

///|
/// 把编码值（0..1）变换为 PCS XYZ。
///
/// 步骤：逐通道 TRC 线性化 → 矩阵乘。
pub fn MatrixTrcTransform::to_pcs(
  self : MatrixTrcTransform,
  r : Double,
  g : Double,
  b : Double,
) -> XyzNumber {
  let linear = XyzNumber::{
    x: self.trc_r.evaluate(r),
    y: self.trc_g.evaluate(g),
    z: self.trc_b.evaluate(b),
  }
  self.matrix.mul(linear)
}

///|
/// 由三刺激值构造。
pub fn XyzNumber::new(x : Double, y : Double, z : Double) -> XyzNumber {
  { x, y, z, }
}

///|
/// PCS 白点 D50 的 XYZ 值。
///
/// 依据 ICC 规范，PCS 照明体固定为 D50：
/// `X = 0.9642`、`Y = 1.0`、`Z = 0.8249`。
pub let d50_white : XyzNumber = { x: 0.9642, y: 1.0, z: 0.8249, }

///|
/// Lab 值。`l` 取 0..100，`a`/`b` 为有符号值。
pub struct Lab {
  l : Double
  a : Double
  b : Double
}

///|
/// 由分量构造 Lab。
pub fn Lab::new(l : Double, a : Double, b : Double) -> Lab {
  { l, a, b, }
}

///|
/// XYZ → Lab 的立方根项。
///
/// 依据 CIE 定义：`t > (6/29)^3` 时用 `t^(1/3)`，否则用线性段。
fn lab_f(t : Double) -> Double {
  let delta = 6.0 / 29.0
  let delta3 = delta * delta * delta
  if t > delta3 {
    @math.cbrt(t)
  } else {
    t / (3.0 * delta * delta) + 4.0 / 29.0
  }
}

///|
/// Lab → XYZ 的逆立方根项。
fn lab_f_inv(t : Double) -> Double {
  let delta = 6.0 / 29.0
  if t > delta {
    t * t * t
  } else {
    3.0 * delta * delta * (t - 4.0 / 29.0)
  }
}

///|
/// XYZ → Lab，以 D50 为参考白点。
pub fn xyz_to_lab(xyz : XyzNumber) -> Lab {
  let fx = lab_f(xyz.x / d50_white.x)
  let fy = lab_f(xyz.y / d50_white.y)
  let fz = lab_f(xyz.z / d50_white.z)
  { l: 116.0 * fy - 16.0, a: 500.0 * (fx - fy), b: 200.0 * (fy - fz), }
}

///|
/// Lab → XYZ，以 D50 为参考白点。
pub fn lab_to_xyz(lab : Lab) -> XyzNumber {
  let fy = (lab.l + 16.0) / 116.0
  let fx = fy + lab.a / 500.0
  let fz = fy - lab.b / 200.0
  {
    x: lab_f_inv(fx) * d50_white.x,
    y: lab_f_inv(fy) * d50_white.y,
    z: lab_f_inv(fz) * d50_white.z,
  }
}

///|
/// CIE76 色差 ΔE*ab。
pub fn delta_e76(a : Lab, b : Lab) -> Double {
  let dl = a.l - b.l
  let da = a.a - b.a
  let db = a.b - b.b
  @math.pow(dl * dl + da * da + db * db, 0.5)
}
