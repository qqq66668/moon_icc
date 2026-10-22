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
/// **颜色映射误差**：PCS → 设备 → PCS 的往返 ΔE76。
///
/// 这个量衡量的是「同一个 profile 的 A2B 与 B2A 有多不互逆」——
/// 它们本就是两张独立的表，CMYK 还受 GCR 与总墨量限制。
///
/// **它不用于色域判定**（那是 `gamut.mbt` 的球面边界描述符的职责）。
/// 之所以保留这个 API：它是打样链与设备特性的一手指标，也用于在
/// README 中量化「映射误差」与「真实越界」的区别。
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
/// 中性轴上的**映射误差基线**：若干中性灰往返 ΔE76 的中位数。
///
/// 本机 Agfa SWOP CMYK profile 实测约 4.5 ΔE——这全部是映射误差，
/// 与色域无关。上一版曾把它当色域判定的容差基准，实测证明那条路走不通
/// （见 `gamut.mbt` 顶部的量化说明）。
pub fn Profile::neutral_mapping_error(
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
