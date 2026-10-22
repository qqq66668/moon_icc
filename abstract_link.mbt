///|
/// 抽象 profile（`abst`）与 device link profile（`link`）的变换入口。
///
/// 这两类 profile 不走「设备 ↔ PCS」的常规链：
///
/// - **`abst`（抽象）**：输入输出**都在 PCS**（`color_space` 与 `pcs` 都是
///   `Lab ` 或 `XYZ `），典型用途是色彩偏好调整，串在 ICC 链的中间；
/// - **`link`（设备链接）**：`pcs` 字段此时记的是**目标设备空间**，
///   A2B 直接把源设备值映射成目标设备值，不经过 PCS。
///
/// 二者的共同点是都可以复用 `LutTable`，只是输入/输出的编码方式不同。

///|
/// 抽象 profile：PCS → PCS。
///
/// 输入按 profile 的 `color_space` 编码（`Lab ` 或 `XYZ `），
/// 输出按 `pcs` 编码；两者的 v2/v4 Lab 编码差异由 profile 版本决定。
pub fn Profile::apply_abstract(
  self : Profile,
  intent : Int32,
  xyz : XyzNumber,
) -> XyzNumber raise IccError {
  let table = self.a2b(intent)
  let is_v2 = table.pcs_is_v2(self.is_v2())
  let depth = table.bit_depth()
  let encoded = match self.header.color_space {
    "Lab " => lab_to_clut_input(xyz_to_lab(xyz), depth, is_v2)
    "XYZ " => xyz_to_clut_input(xyz, depth)
    other =>
      raise BadTagData(
        tag="A2B0",
        reason="抽象 profile 的输入应为 PCS（Lab 或 XYZ），实际 \"\{other}\"",
      )
  }
  let raw = table.evaluate(encoded)
  match self.header.pcs {
    "Lab " => lab_to_xyz(clut_output_to_lab(raw, depth, is_v2))
    "XYZ " => clut_output_to_xyz(raw, depth)
    other =>
      raise BadTagData(
        tag="A2B0",
        reason="抽象 profile 的输出应为 PCS（Lab 或 XYZ），实际 \"\{other}\"",
      )
  }
}

///|
/// device link profile：源设备值 → 目标设备值。
///
/// 不经过 PCS，因此返回的数组就是目标设备的通道值；
/// 通道数由 A2B 表的输出通道数决定（如 RGB → CMYK 得 4 个值）。
pub fn Profile::apply_device_link(
  self : Profile,
  intent : Int32,
  inputs : Array[Double],
) -> Array[Double] raise IccError {
  self.a2b(intent).evaluate(inputs)
}

///|
/// 该 profile 是否是抽象 profile。
pub fn Profile::is_abstract(self : Profile) -> Bool {
  self.header.device_class == "abst"
}

///|
/// 该 profile 是否是 device link profile。
pub fn Profile::is_device_link(self : Profile) -> Bool {
  self.header.device_class == "link"
}
