///|
/// 软打样与色域判断。
///
/// 这两件事是同一套 PCS 往返能力的两个用法：
///
/// - **软打样**：源设备 → PCS → 「目标设备（打样）往返」 → PCS → 显示设备。
///   中间那次往返把超出目标设备色域的颜色按该设备的实际能力裁掉，
///   于是屏幕上看到的就是印刷后的损失。
/// - **色域判断**：PCS → 目标设备 → PCS 的往返误差（ΔE76）。
///   色域内的颜色往返应几乎无损；被裁剪的颜色往返会明显偏离。

///|
/// 软打样链。
///
/// ```text
/// 源设备值 --A2B--> PCS --B2A--> 打样设备值 --A2B--> PCS --B2A--> 显示设备值
/// ```
///
/// 打样 profile 的两个方向都用 `proof_intent`；源与显示用 `intent`。
/// 绝对比色会在两个 PCS 交界处引入白点缩放（见 `ColorTransform` 的说明），
/// 缩放取相邻两侧的媒体白点之比。
pub struct ProofTransform {
  /// 源侧：源设备值 → PCS。
  source : SourceStage
  /// 打样侧：PCS → 打样设备值。
  proof_dest : DestinationStage
  /// 打样侧：打样设备值 → PCS。
  proof_source : SourceStage
  /// 显示侧：PCS → 显示设备值。
  display : DestinationStage
  /// 源 → 打样 交界处的 PCS 缩放（绝对比色时非 1）。
  source_scale : XyzNumber
  /// 打样 → 显示 交界处的 PCS 缩放（绝对比色时非 1）。
  display_scale : XyzNumber
  /// 源/显示侧使用的意图。
  intent : Int32
  /// 打样 profile 使用的意图。
  proof_intent : Int32
}

///|
/// 按分量缩放 PCS XYZ。
fn scale_xyz(xyz : XyzNumber, scale : XyzNumber) -> XyzNumber {
  XyzNumber::new(xyz.x * scale.x, xyz.y * scale.y, xyz.z * scale.z)
}

///|
/// 两个媒体白点的分量比 `diag(a / b)`，用作绝对比色的 PCS 缩放。
fn white_scale(a : XyzNumber, b : XyzNumber) -> XyzNumber {
  XyzNumber::new(a.x / b.x, a.y / b.y, a.z / b.z)
}

///|
/// 构造软打样链。
///
/// | 参数 | 含义 |
/// |------|------|
/// | `source` | 图像所在设备（如 sRGB 相机/显示器） |
/// | `proof` | 要模拟的目标设备（如 CMYK 印刷机） |
/// | `display` | 观察者实际使用的显示设备 |
/// | `intent` | 源与显示侧意图（通常 1 = 媒体相对比色） |
/// | `proof_intent` | 打样 profile 两个方向的意图（通常 1，或 3 = 绝对比色） |
pub fn ColorTransform::proofing(
  source : Profile,
  proof : Profile,
  display : Profile,
  intent : Int32,
  proof_intent : Int32,
) -> ProofTransform raise IccError {
  if intent < 0 || intent > 3 {
    raise BadTagData(
      tag="renderingIntent",
      reason="源/显示侧意图编号应在 0..3，实际 \{intent}",
    )
  }
  if proof_intent < 0 || proof_intent > 3 {
    raise BadTagData(
      tag="proofingIntent",
      reason="打样意图编号应在 0..3，实际 \{proof_intent}",
    )
  }
  let src_white = source.media_white_point()
  let proof_white = proof.media_white_point()
  let disp_white = display.media_white_point()
  let ones = XyzNumber::new(1.0, 1.0, 1.0)
  {
    source: build_source(source, intent),
    proof_dest: build_destination(proof, proof_intent),
    proof_source: build_source(proof, proof_intent),
    display: build_destination(display, intent),
    source_scale: if intent == 3 {
      white_scale(src_white, proof_white)
    } else {
      ones
    },
    display_scale: if proof_intent == 3 {
      white_scale(proof_white, disp_white)
    } else {
      ones
    },
    intent,
    proof_intent,
  }
}

///|
/// 打样链求值：返回 `(打样设备值, 显示设备值)`。
///
/// 两个结果都有用：前者是「这张图印在目标设备上会用哪些墨量」，
/// 后者是「屏幕上应该显示成什么」。
pub fn ProofTransform::evaluate(
  self : ProofTransform,
  inputs : Array[Double],
) -> (Array[Double], Array[Double]) {
  let pcs0 = scale_xyz(self.source.to_pcs(inputs), self.source_scale)
  let proof_values = self.proof_dest.from_pcs(pcs0)
  let pcs1 = scale_xyz(
    self.proof_source.to_pcs(proof_values),
    self.display_scale,
  )
  (proof_values, self.display.from_pcs(pcs1))
}

///|
/// 打样链求值（只取显示设备值）。
pub fn ProofTransform::transform_values(
  self : ProofTransform,
  inputs : Array[Double],
) -> Array[Double] {
  let (_, shown) = self.evaluate(inputs)
  shown
}

///|
/// 源/显示侧使用的意图编号。
pub fn ProofTransform::intent(self : ProofTransform) -> Int32 {
  self.intent
}

///|
/// 打样 profile 使用的意图编号。
pub fn ProofTransform::proof_intent(self : ProofTransform) -> Int32 {
  self.proof_intent
}

///|
/// 目标阶段的设备通道数（如 CMYK 为 4）。
fn DestinationStage::device_channels(self : DestinationStage) -> Int32 {
  match self {
    MatrixTrcDest(_) => 3
    LutDest(stage) => stage.table.output_channels()
  }
}

///|
/// 打样设备值 → 设备值通道数（如 CMYK 为 4）。
pub fn ProofTransform::proof_channels(self : ProofTransform) -> Int32 {
  self.proof_dest.device_channels()
}

///|
/// 显示设备值通道数。
pub fn ProofTransform::display_channels(self : ProofTransform) -> Int32 {
  self.display.device_channels()
}

///|
/// 色域往返误差：PCS → 设备 → PCS 的 ΔE76。
///
/// 这是「该颜色能否被这台设备表达」的直接度量：
/// 色域内的颜色往返几乎无损（只剩下 8 位 CLUT 的量化误差），
/// 被色域边界裁掉的颜色往返后会明显偏离。
///
/// 用 ΔE76 而不是 ΔE2000：本库只实现了 CIE76，且这一判据比较的是
/// 「同一颜色往返前后」的差异，ΔE76 与 ΔE2000 在这里单调同向。
pub fn Profile::round_trip_delta_e(
  self : Profile,
  intent : Int32,
  xyz : XyzNumber,
) -> Double raise IccError {
  let dest = build_destination(self, intent)
  let src = build_source(self, intent)
  let device = dest.from_pcs(xyz)
  let back = src.to_pcs(device)
  delta_e76(xyz_to_lab(xyz), xyz_to_lab(back))
}

///|
/// 中性轴往返基线：若干中性灰的往返 ΔE76 中位数。
///
/// 为什么需要它：**同一个 profile 的 A2B 与 B2A 是两张独立的表**，互相不是
/// 严格的逆——CMYK 打印机受 GCR 与总墨量限制，中性灰往返本就有几个 ΔE 的
/// 底噪（本机 Agfa SWOP profile 实测约 4.5）。若用固定的绝对阈值，
/// 会把明明在色域内的灰阶判成超色域。
///
/// 因此色域判断以**这台设备自己的中性轴底噪**为基线，见 `Profile::gamut_tolerance`。
pub fn Profile::neutral_round_trip_baseline(
  self : Profile,
  intent : Int32,
) -> Double raise IccError {
  let probe : Array[Double] = [20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0]
  let errs : Array[Double] = []
  for l in probe {
    errs.push(
      self.round_trip_delta_e(intent, lab_to_xyz(Lab::new(l, 0.0, 0.0))),
    )
  }
  errs.sort()
  errs[errs.length() / 2]
}

///|
/// 该 profile 的色域判定容差（ΔE76）。
///
/// 取「中性轴基线 × 1.25」，下限 2.0。1.25 的含义是：允许比中性轴底噪再高
/// 25% 的偏差——中性色本身不判超色域，而明显被设备边界裁掉的颜色
/// （实测 ΔE 从 12 起步）会被判出来。
///
/// 这是**启发式判据**，不是 ICC 规范里的定义；需要别的口径时可以直接用
/// `round_trip_delta_e` 自己定阈值。
pub fn Profile::gamut_tolerance(
  self : Profile,
  intent : Int32,
) -> Double raise IccError {
  let scaled = self.neutral_round_trip_baseline(intent) * 1.25
  if scaled < 2.0 {
    2.0
  } else {
    scaled
  }
}

///|
/// 色域判断：往返误差不超过**该 profile 的自适应容差**即认为在色域内。
///
/// 判据的两个已知性质（都有测试钉住）：
/// - 中性灰与纸白判为「在色域内」；
/// - 纯黑与高饱和 RGB 原色判为「超色域」——这是物理事实：纸上最深的黑
///   达不到 L*=0，SWOP 类 CMYK 也覆盖不了 sRGB 的原色。
pub fn Profile::in_gamut(
  self : Profile,
  intent : Int32,
  xyz : XyzNumber,
) -> Bool raise IccError {
  self.round_trip_delta_e(intent, xyz) <= self.gamut_tolerance(intent)
}
