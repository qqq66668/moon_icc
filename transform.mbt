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
/// 矩阵行列式。零行列式意味着不可逆。
pub fn Matrix3::determinant(self : Matrix3) -> Double {
  let a = self.col0
  let b = self.col1
  let c = self.col2
  a.x * (b.y * c.z - b.z * c.y) -
  b.x * (a.y * c.z - a.z * c.y) +
  c.x * (a.y * b.z - a.z * b.y)
}

///|
/// 矩阵求逆（伴随矩阵除以行列式）。
///
/// 行列式为零时返回 `None`——调用方须显式处理，不能假定可逆。
/// ICC profile 的矩阵理论上总是可逆的（三原色线性无关），
/// 但 profile 是外部不可信输入，因此必须检查。
pub fn Matrix3::inverse(self : Matrix3) -> Matrix3? {
  let det = self.determinant()
  // 阈值取 1e-12：矩阵元素量级约 0.1..1，行列式量级约 0.01..0.5，
  // 远大于该阈值；真出现接近零的行列式说明 profile 畸形。
  if det > -1.0e-12 && det < 1.0e-12 {
    return None
  }
  let a = self.col0
  let b = self.col1
  let c = self.col2
  // 原矩阵按列存为 a,b,c，即 M = [[a.x,b.x,c.x],[a.y,b.y,c.y],[a.z,b.z,c.z]]。
  //
  // 下面的 `cIJ` 是 M 的第 I 行第 J 列的余子式（cofactor），
  // 即删去第 I 行第 J 列后的 2×2 行列式乘以 (-1)^(I+J)。
  // 用于构成逆矩阵时，M⁻¹ 的第 I 行第 J 列 = cJI / det（注意下标互换，
  // 这正是"伴随矩阵 = 余子式矩阵的转置"）。
  let c00 = b.y * c.z - b.z * c.y
  let c01 = -(a.y * c.z - a.z * c.y)
  let c02 = a.y * b.z - a.z * b.y
  let c10 = -(b.x * c.z - b.z * c.x)
  let c11 = a.x * c.z - a.z * c.x
  let c12 = -(a.x * b.z - a.z * b.x)
  let c20 = b.x * c.y - b.y * c.x
  let c21 = -(a.x * c.y - a.y * c.x)
  let c22 = a.x * b.y - a.y * b.x
  // M⁻¹ 的行 I 为 (cI0, cI1, cI2) / det。
  // 按列存储时，第 0 列 = M⁻¹ 各行的第 0 个元素 = (c00, c10, c20) / det。
  //
  // M⁻¹ 的**列** J 为 (c0J, c1J, c2J) / det。
  //
  // 注意：这里曾有 bug——初版误写成 (c00, c10, c20)，那是 M⁻¹ 的**行** 0，
  // 等于把逆矩阵转置了，结果与 lcms2 相差最大 173/255。
  // 修正依据：与 numpy.linalg.inv 的结果逐项比对（见 tools/ 下的验证脚本）。
  Some(
    Matrix3::new(
      XyzNumber::{ x: c00 / det, y: c01 / det, z: c02 / det, },
      XyzNumber::{ x: c10 / det, y: c11 / det, z: c12 / det, },
      XyzNumber::{ x: c20 / det, y: c21 / det, z: c22 / det, },
    ),
  )
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

///|
/// 逆变换：PCS XYZ → 设备编码值。
///
/// `MatrixTrcTransform` 持有的是"正变换"上下文（矩阵与正向曲线），
/// 逆变换需要矩阵的逆与曲线的反函数。为避免每次调用都重新求逆，
/// 这里单独构造一个逆变换上下文。
pub struct InverseMatrixTrc {
  /// 矩阵的逆。
  inverse_matrix : Matrix3
  /// 红通道的反曲线。
  inv_r : InverseCurve
  /// 绿通道的反曲线。
  inv_g : InverseCurve
  /// 蓝通道的反曲线。
  inv_b : InverseCurve
}

///|
/// 构造逆变换上下文。矩阵不可逆时报错。
pub fn MatrixTrcTransform::inverse(
  self : MatrixTrcTransform,
) -> InverseMatrixTrc raise IccError {
  match self.matrix.inverse() {
    Some(inv) =>
      {
        inverse_matrix: inv,
        inv_r: invert_curve(self.trc_r),
        inv_g: invert_curve(self.trc_g),
        inv_b: invert_curve(self.trc_b),
      }
    None =>
      raise BadTagData(
        tag="rXYZ/gXYZ/bXYZ",
        reason="矩阵行列式为零，无法求逆",
      )
  }
}

///|
/// 逆变换求值：XYZ → 设备编码值。
///
/// 步骤：矩阵求逆得到线性值 → 逐通道套反曲线 → 夹到 [0,1]。
pub fn InverseMatrixTrc::from_pcs(
  self : InverseMatrixTrc,
  xyz : XyzNumber,
) -> (Double, Double, Double) {
  let linear = self.inverse_matrix.mul(xyz)
  (
    clamp01(self.inv_r.evaluate(linear.x)),
    clamp01(self.inv_g.evaluate(linear.y)),
    clamp01(self.inv_b.evaluate(linear.z)),
  )
}

///|
/// 逆变换专用的曲线表示。
///
/// `curv` 表型曲线是**等间距采样**的（表项 `i` 对应输入 `i/(n-1)`），
/// 因此求逆不该"先重采样成一张新表再插值"——那会在极暗区
/// （曲线陡、输出接近 0）引入可观的二次误差。
/// 正确做法是**在表值域上直接反查**：找到第一个表值 ≥ target 的索引，
/// 在该索引与前一索引之间按表值线性插值得到输入。
///
/// 实测：早期用"重采样 1025 点 + 插值"的做法，在 sRGB→显示器 profile
/// 的 i=1（最暗一级）上输出 4/255，而 lcms2 与纯数学参考实现均为 9/255。
enum InverseCurve {
  /// gamma 型：直接解析求逆。
  GammaInv(Double)
  /// 表型：保存原表，在表值域反查。
  TableInv(Array[Double])
  /// 参数型：无解析逆，保留原曲线用二分法数值求逆。
  NumericInv(ToneCurve)
}

///|
/// 构造逆曲线。
fn invert_curve(c : ToneCurve) -> InverseCurve {
  match c {
    Gamma(g) => if g == 0.0 { GammaInv(1.0) } else { GammaInv(1.0 / g) }
    Table(items) => TableInv(items)
    Parametric(_) => NumericInv(c)
  }
}

///|
/// 对逆曲线求值。
pub fn InverseCurve::evaluate(self : InverseCurve, y : Double) -> Double {
  let v = clamp01(y)
  match self {
    GammaInv(g) => if g == 1.0 { v } else { @math.pow(v, g) }
    TableInv(items) => invert_table_at(items, v)
    NumericInv(c) => bisect(c, v)
  }
}

///|
/// 在等间距采样的表中反查：给定表值 `target`，求对应的输入。
///
/// 表值单调不减（ICC 要求曲线单调）。做法：
/// 线性扫描找到第一个 `items[i] >= target` 的 `i`，
/// 在 `[i-1, i]` 的表值区间内线性插值——这正是正向插值的逆运算。
///
/// 扫描而非二分：表通常只有几百到几千项，且这是逆变换热路径，
/// 线性扫描的分支预测行为更好；实测 1024 项表在 256 个样本上无性能问题。
fn invert_table_at(items : Array[Double], target : Double) -> Double {
  let n = items.length()
  if n == 0 {
    return target
  }
  if n == 1 {
    return 0.0
  }
  if target <= items[0] {
    return 0.0
  }
  if target >= items[n - 1] {
    return 1.0
  }
  let mut i = 1
  while i < n {
    if items[i] >= target {
      break
    }
    i = i + 1
  }
  if i >= n {
    return 1.0
  }
  let lo_val = items[i - 1]
  let hi_val = items[i]
  let span = hi_val - lo_val
  let x_lo = (i - 1).to_double() / (n - 1).to_double()
  let x_hi = i.to_double() / (n - 1).to_double()
  if span <= 0.0 {
    // 平台区：返回该段右端，避免除零
    x_hi
  } else {
    let frac = (target - lo_val) / span
    x_lo + (x_hi - x_lo) * frac
  }
}

///|
/// 二分法求 `x` 使 `c.evaluate(x) == target`。
///
/// 仅用于参数化曲线（无解析逆）。返回满足 `c.evaluate(x) >= target`
/// 的最小 x 的近似值。60 次迭代足以收敛到双精度极限。
fn bisect(c : ToneCurve, target : Double) -> Double {
  let mut lo = 0.0
  let mut hi = 1.0
  for i = 0; i < 60; i = i + 1 {
    let mid = (lo + hi) / 2.0
    if c.evaluate(mid) < target {
      lo = mid
    } else {
      hi = mid
    }
  }
  hi
}

///|
/// 端到端色彩管理：源设备 RGB → PCS → 目标设备 RGB。
///
/// 使用**媒体相对比色**意图。这是 matrix/TRC 型 profile 唯一
/// 有明确数学定义、且不依赖 profile 内 LUT 的意图：
///
/// - 感知与饱和度意图需要 gamut mapping，通常由 profile 内的
///   LUT（`A2B0`/`A2B1` 等）承载；matrix/TRC 型 profile 没有这些 LUT，
///   参考实现（lcms2）在此情形下也会退化为相对比色；
/// - 绝对比色需要源媒体的绝对白点亮度，超出 ICC profile 本身携带的信息。
///
/// ## 白点处理
///
/// 两个 profile 的矩阵**已经**各自完成到 D50 的色适应，
/// 因此这里在 PCS 中直接衔接，**不再**做额外的白点适应。
pub struct ColorTransform {
  /// 源侧：设备 → PCS XYZ。
  source : SourceStage
  /// 目标侧：PCS XYZ → 设备。
  destination : DestinationStage
  /// 渲染意图编号（0..3）。
  ///
  /// 对 LUT 型 profile，意图在构造时就已体现为「选哪张表」；这里保留编号
  /// 是为了让调用方能查询，并供未来实现绝对比色的 PCS 缩放使用。
  intent : Int32
}

///|
/// 源侧（设备 → PCS）的两种实现。
///
/// LUT 分支存的是 **A2B** 表：输入设备值，输出 PCS Lab。
enum SourceStage {
  /// matrix/TRC 型：直接得到 PCS XYZ。
  MatrixTrcSource(MatrixTrcTransform)
  /// LUT 型：A2B 表输出 PCS Lab，需再转 XYZ 以统一中间表示。
  /// 第二个参数表示该 profile 是否使用 ICC v2 的 PCS 编码。
  LutSource(Clut, Bool)
}

///|
/// 目标侧（PCS → 设备）的两种实现。
///
/// LUT 分支存的是 **B2A** 表：输入 PCS Lab，输出设备值。
enum DestinationStage {
  /// matrix/TRC 型：由 XYZ 求逆得到设备值。
  MatrixTrcDest(InverseMatrixTrc)
  /// LUT 型：由 XYZ 转 Lab 后查 B2A 表。
  /// 第二个参数表示该 profile 是否使用 ICC v2 的 PCS 编码。
  LutDest(Clut, Bool)
}

///|
/// 该 profile 是否具备 matrix/TRC 变换所需的全部 tag。
///
/// 用于在构造链接时决定走哪条路径，而不必靠捕获异常来试探。
pub fn Profile::has_matrix_trc(self : Profile) -> Bool {
  let has = fn(sig : String) -> Bool {
    match self.find_tag(sig) {
      Some(_) => true
      None => false
    }
  }
  has("rXYZ") &&
  has("gXYZ") &&
  has("bXYZ") &&
  has("rTRC") &&
  has("gTRC") &&
  has("bTRC")
}

///|
/// 该 profile 是否具备 LUT 变换所需的 A2B tag。
pub fn Profile::has_lut(self : Profile) -> Bool {
  let has = fn(sig : String) -> Bool {
    match self.find_tag(sig) {
      Some(_) => true
      None => false
    }
  }
  has("A2B0") || has("A2B1") || has("A2B2")
}

///|
/// 构造源侧。
fn build_source(
  profile : Profile,
  intent : Int32,
) -> SourceStage raise IccError {
  if profile.has_matrix_trc() {
    MatrixTrcSource(profile.matrix_trc())
  } else if profile.has_lut() {
    LutSource(profile.a2b(intent), profile.is_v2())
  } else {
    raise BadTagData(
      tag="A2B0",
      reason="profile 既没有 matrix/TRC tag，也没有 A2B LUT tag，无法做设备到 PCS 变换",
    )
  }
}

///|
/// 构造目标侧。
fn build_destination(
  profile : Profile,
  intent : Int32,
) -> DestinationStage raise IccError {
  if profile.has_matrix_trc() {
    MatrixTrcDest(profile.matrix_trc().inverse())
  } else if profile.has_lut() {
    LutDest(profile.b2a(intent), profile.is_v2())
  } else {
    raise BadTagData(
      tag="B2A0",
      reason="profile 既没有 matrix/TRC tag，也没有 B2A LUT tag，无法做 PCS 到设备变换",
    )
  }
}

///|
/// 构造源→目标的端到端变换，使用**媒体相对比色**（编号 1）。
///
/// 两侧各自可以是 matrix/TRC 型或 LUT 型，四种组合都支持：
/// 中间统一用 PCS XYZ 衔接。因此 sRGB → CMYK 打印机这样的跨类型链接可用。
pub fn ColorTransform::new(
  source : Profile,
  destination : Profile,
) -> ColorTransform raise IccError {
  ColorTransform::with_intent(source, destination, 1)
}

///|
/// 构造源→目标的端到端变换，指定渲染意图。
///
/// | 编号 | 意图 | 对 LUT 型 profile 的效果 |
/// |------|------|------------------------|
/// | 0 | 感知 | 用 `A2B0`/`B2A0` |
/// | 1 | 媒体相对比色 | 用 `A2B1`/`B2A1` |
/// | 2 | 饱和度 | 用 `A2B2`/`B2A2` |
/// | 3 | 绝对比色 | 同 1（**已知限制**，见下） |
///
/// **matrix/TRC 型 profile 四种意图等价**：这类 profile 只有一组矩阵与曲线，
/// 没有按意图分开的数据。这不是本库的省略——实测 lcms2 对
/// sRGB → 显示器 这组 profile 对，四种意图给出**逐位相同**的结果
/// （见 `tools/lcms2_intent_check.py`）。
///
/// 反之对含多个 LUT 的 profile（如本机 CMYK 打印机），意图确实可区分：
/// 实测以媒体相对比色为基准，感知差 35 级、饱和度差 255 级、绝对差 20 级。
///
/// ## 绝对比色（编号 3）为什么与 1 相同
///
/// 绝对比色需要在 PCS 上做白点缩放。本项目尝试过
/// 「源侧乘 `wtpt/D50`、目标侧乘 `D50/wtpt`」这一标准形式，实测与 lcms2 的
/// 偏差从 20 级**恶化到 107 级**，说明该形式与参考实现的实际语义不符。
///
/// 由于无法从可用材料确定参考实现的绝对比色语义，本库**不实现**它，
/// 而是让编号 3 走与相对比色相同的路径（与 lcms2 的差异 ≤ 20 级），
/// 并在 README 的「明确不做」中如实记录。发布一个会把结果改坏的猜测实现，
/// 比承认这项限制更糟。
///
/// 非法编号（负数或大于 3）会被拒绝，不静默回退到默认意图。
pub fn ColorTransform::with_intent(
  source : Profile,
  destination : Profile,
  intent : Int32,
) -> ColorTransform raise IccError {
  if intent < 0 || intent > 3 {
    raise BadTagData(
      tag="renderingIntent",
      reason="渲染意图编号应在 0..3，实际 \{intent}",
    )
  }
  {
    source: build_source(source, intent),
    destination: build_destination(destination, intent),
    intent,
  }
}

///|
/// 该变换使用的渲染意图编号。
pub fn ColorTransform::intent(self : ColorTransform) -> Int32 {
  self.intent
}

///|
/// 源侧通道数（目标色空间的通道数由 profile 决定，如 CMYK 为 4）。
pub fn ColorTransform::source_channels(self : ColorTransform) -> Int32 {
  match self.source {
    MatrixTrcSource(_) => 3
    LutSource(table, _) => table.input_channels
  }
}

///|
/// 目标侧通道数。
pub fn ColorTransform::destination_channels(self : ColorTransform) -> Int32 {
  match self.destination {
    MatrixTrcDest(_) => 3
    LutDest(table, _) => table.output_channels
  }
}

///|
/// 设备值 → PCS XYZ。
///
/// matrix/TRC 型直接得到 XYZ；LUT 型先得到 Lab 再转 XYZ，
/// 使中间表示统一，从而两类 profile 可以任意组合。
fn SourceStage::to_pcs(self : SourceStage, inputs : Array[Double]) -> XyzNumber {
  match self {
    MatrixTrcSource(t) =>
      t.to_pcs(
        if inputs.length() > 0 {
          inputs[0]
        } else {
          0.0
        },
        if inputs.length() > 1 {
          inputs[1]
        } else {
          0.0
        },
        if inputs.length() > 2 {
          inputs[2]
        } else {
          0.0
        },
      )
    LutSource(table, is_v2) => {
      let raw = table.evaluate(inputs)
      lab_to_xyz(clut_output_to_lab(raw, table.bit_depth, is_v2))
    }
  }
}

///|
/// PCS XYZ → 设备值。
fn DestinationStage::from_pcs(
  self : DestinationStage,
  xyz : XyzNumber,
) -> Array[Double] {
  match self {
    MatrixTrcDest(inv) => {
      let (r, g, b) = inv.from_pcs(xyz)
      [r, g, b]
    }
    LutDest(table, is_v2) => {
      let encoded = lab_to_clut_input(xyz_to_lab(xyz), table.bit_depth, is_v2)
      table.evaluate(encoded)
    }
  }
}

///|
/// 端到端变换求值（通用形式，支持任意通道数）。
///
/// 输入按**源 profile 色空间**的通道顺序给出，输出按**目标 profile 色空间**
/// 的通道顺序。例如 sRGB → CMYK 时输入 3 个值、输出 4 个值。
pub fn ColorTransform::transform_values(
  self : ColorTransform,
  inputs : Array[Double],
) -> Array[Double] {
  // 注意：**不做**绝对比色的白点缩放。
  //
  // 曾按「源侧乘 wtpt/D50、目标侧乘 D50/wtpt」实现过，实测与 lcms2 的
  // 偏差从 20 级**恶化到 107 级**，说明该公式与参考实现的绝对比色语义不符。
  // 与其发布一个把结果改坏的猜测实现，不如维持与相对比色一致，
  // 并把差异如实记录（见 README 的「明确不做」与 intent_wbtest.mbt）。
  self.destination.from_pcs(self.source.to_pcs(inputs))
}

///|
/// 端到端变换求值（3 通道便捷形式）。
///
/// 仅用于源与目标都是 3 通道的情形（如 sRGB → 显示器）。跨类型或 CMYK
/// 场景请用 `transform_values`。
pub fn ColorTransform::transform(
  self : ColorTransform,
  r : Double,
  g : Double,
  b : Double,
) -> (Double, Double, Double) {
  let out = self.transform_values([r, g, b])
  let get = fn(i : Int32) -> Double {
    if i < out.length() {
      out[i]
    } else {
      0.0
    }
  }
  (get(0), get(1), get(2))
}
