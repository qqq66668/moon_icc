///|
/// 一致性（conformance）检查：规范版本、profile 类的必需 tag、覆盖目标。
///
/// 本文件回答评审的第二个问题——「明确『完整 ICC 引擎』的标准版本及必需行为
/// 的完整覆盖目标」：把"覆盖"落成**可执行的检查**，而不是散文描述。
///
/// 依据：ICC.1:2010-12（ISO 15076-1:2010）第 8、9 章与附录的表 17–23
/// （按设备类列出的必需/可选 tag）。本实现只检查 **tag 是否存在**，
/// 不检查 tag 内容是否符合规范（内容检查由各 tag 的解析器与测试承担）。

///|
/// 目标规范版本：ICC.1:2010-12（profile version 4.3），并向下兼容
/// ICC.1:2001-04（v2.x）的既有 profile。
///
/// 明确排除：iccMAX（ICC.2，完全不同的架构）、profile v5（不存在该版本号）。
pub let target_specification : String = "ICC.1:2010-12 (ISO 15076-1:2010), profile v4.3 + v2.x"

///|
/// 一个 profile 的一致性报告。
pub struct ConformanceReport {
  /// 设备类（`mntr`/`scnr`/`prtr`/`spac`/`abst`/`link`/`nmcl`）。
  device_class : String
  /// 规范版本字符串（如 "4.3" 或 "2.1"）。
  version : String
  /// 该类的必需 tag 清单。
  required : Array[String]
  /// 缺失的必需 tag。
  missing : Array[String]
  /// 本库对该类是否提供变换能力。
  transform_supported : Bool
  /// 备注（该类在本库中的边界）。
  note : String
  /// profile 里 `A2B0-2` / `B2A0-2` 的实有张数（用于判断 v4 覆盖度）。
  lut_count : Int32
  /// 本库对该设备类的支持水平：`已验证` / `部分` / `不支持`。
  support_level : String
}

///|
/// 该设备类的必需 tag（依据 ICC.1:2010 表 17–23，取各类的核心必需项）。
///
/// 说明：规范里部分 tag 允许"二选一"（例如输入类可以是 matrix/TRC，
/// 也可以是 A2B 系列）。这里把「共同必需」与「至少一项」分开列出：
/// 共同必需的放在返回值里，二选一的用 `class_alternative_tags` 给出。
pub fn required_tags_for_class(device_class : String) -> Array[String] {
  // 描述与版权在除了 deviceLink 之外的类里都必需；deviceLink 也要求 desc/cprt
  let common : Array[String] = ["desc", "cprt"]
  let extra : Array[String] = match device_class {
    "scnr" => ["wtpt"]
    "mntr" => ["wtpt"]
    "prtr" => ["wtpt"]
    "spac" => ["wtpt"]
    "abst" => []
    "link" => []
    "nmcl" => ["wtpt"]
    _ => []
  }
  common + extra
}

///|
/// 该设备类的**完整候选 set**：每个 set 内的 tag 必须**全部存在**，
/// 只要有一个 set 成立即视为满足（规范里"matrix/TRC 型 **或** LUT 型"的语义）。
///
/// 这是本实现的一处明确简化：只检查 tag 是否存在，不检查 LUT 张数是否
/// 覆盖全部意图（v4 输出类规范上要求 A2B0-2 与 B2A0-2 共 6 张；
/// 张数不足会在 `ConformanceReport` 的备注里给出提示）。
pub fn class_required_sets(device_class : String) -> Array[Array[String]] {
  match device_class {
    "scnr" | "mntr" | "spac" =>
      [["rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC"], ["A2B0"]]
    "prtr" => [["A2B0", "B2A0"]]
    "abst" => [["A2B0"]]
    "link" => [["A2B0"]]
    "nmcl" => [["ncl2"]]
    _ => []
  }
}

///|
/// profile 里有哪些 LUT tag（`A2B0-2` / `B2A0-2`），用于备注覆盖率。
fn Profile::lut_inventory(self : Profile) -> Array[String] {
  let names : Array[String] = ["A2B0", "A2B1", "A2B2", "B2A0", "B2A1", "B2A2"]
  let found : Array[String] = []
  for n in names {
    match self.find_tag(n) {
      Some(_) => found.push(n)
      None => ()
    }
  }
  found
}

///|
/// 本库对该设备类的**支持水平**与边界说明。
///
/// 三态，刻意区分"实现了"和"有真实样本验证过"：
/// - `已验证`：有真实 profile + 测试判据；
/// - `部分`：变换入口已实现，但本机没有该类真实样本，判据待补；
/// - `不支持`：本库不做，并给出理由。
fn class_support(device_class : String) -> (String, String) {
  match device_class {
    "scnr" => ("已验证", "设备 → PCS（matrix/TRC 或 A2B LUT）")
    "mntr" => ("已验证", "设备 ↔ PCS（A2B/B2A；matrix/TRC 可逆）")
    "prtr" =>
      ("已验证", "PCS → 设备（B2A），并支持 A2B 用于打样链")
    "spac" =>
      (
        "已验证", "设备 ↔ PCS（工作空间；matrix/TRC 与 LUT 两种都验证过）",
      )
    "abst" =>
      (
        "部分", "PCS → PCS 的变换入口已实现；本机无该类真实样本，判据待补",
      )
    "link" =>
      (
        "部分", "设备 → 设备的变换入口已实现；本机无该类真实样本，判据待补",
      )
    "nmcl" =>
      (
        "不支持", "命名色（ncl2）不做：本库面向设备色彩变换，不处理命名色查表",
      )
    _ => ("不支持", "未知设备类")
  }
}

///|
/// 对一个 profile 做一致性检查。
pub fn Profile::conformance(self : Profile) -> ConformanceReport {
  let device_class = self.header.device_class
  let version = "\{self.header.major_version}.\{self.header.minor_version}"
  let required = required_tags_for_class(device_class)
  let missing : Array[String] = []
  for sig in required {
    match self.find_tag(sig) {
      Some(_) => ()
      None => missing.push(sig)
    }
  }
  // 候选 set：任意一个 set 完整存在即满足；否则把第一个 set 的缺口列出来
  let sets = class_required_sets(device_class)
  if sets.length() > 0 {
    let mut satisfied = false
    for set in sets {
      let mut all = true
      for sig in set {
        match self.find_tag(sig) {
          Some(_) => ()
          None => all = false
        }
      }
      if all {
        satisfied = true
      }
    }
    if !satisfied {
      for sig in sets[0] {
        match self.find_tag(sig) {
          Some(_) => ()
          None => missing.push(sig)
        }
      }
    }
  }
  let (level, base_note) = class_support(device_class)
  let luts = self.lut_inventory()
  let note = base_note + "；共 \{luts.length()} 张 LUT"
  {
    device_class,
    version,
    required,
    missing,
    transform_supported: level != "不支持",
    note,
    lut_count: luts.length(),
    support_level: level,
  }
}

///|
/// 该 profile 是否满足其设备类的必需 tag（共同必需 + 至少一个完整候选 set）。
pub fn ConformanceReport::ok(self : ConformanceReport) -> Bool {
  self.missing.length() == 0
}

///|
/// 是否支持对该 profile 做变换（按设备类判定）。
pub fn ConformanceReport::transform_supported(self : ConformanceReport) -> Bool {
  self.transform_supported
}

///|
/// 设备类。
pub fn ConformanceReport::device_class(self : ConformanceReport) -> String {
  self.device_class
}

///|
/// 规范版本字符串。
pub fn ConformanceReport::version(self : ConformanceReport) -> String {
  self.version
}

///|
/// 缺失的必需 tag。
pub fn ConformanceReport::missing(self : ConformanceReport) -> Array[String] {
  self.missing
}

///|
/// 该类在本库中的边界说明。
pub fn ConformanceReport::note(self : ConformanceReport) -> String {
  self.note
}

///|
/// profile 里 LUT tag 的实有张数（`A2B0-2` / `B2A0-2`）。
pub fn ConformanceReport::lut_count(self : ConformanceReport) -> Int32 {
  self.lut_count
}

///|
/// 覆盖矩阵的一行：设备类 + 支持情况 + 边界说明，供 CLI 与文档使用。
pub fn conformance_matrix() -> Array[(String, String, String)] {
  let classes : Array[String] = [
    "scnr", "mntr", "prtr", "spac", "abst", "link", "nmcl",
  ]
  let rows : Array[(String, String, String)] = []
  for c in classes {
    let (level, note) = class_support(c)
    rows.push((c, level, note))
  }
  rows
}

///|
/// 本库对该 profile 设备类的支持水平（`已验证` / `部分` / `不支持`）。
pub fn ConformanceReport::support_level(self : ConformanceReport) -> String {
  self.support_level
}
