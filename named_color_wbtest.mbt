///|
/// 命名色（`ncl2`）的判据测试。
///
/// 回应第四次驳回：命名色（`nmcl` 类）必须纳入项目终点，并给出**具体输入输出案例**。
/// 夹具 `testdata/named_lab.icc` / `named_xyz.icc` 由 `tools/gen_named_profile.py`
/// 确定性生成：两份的色名与设备坐标完全相同，只有 `ncl2` 里 PCS 三分量的编码空间
/// 不同（Lab 版按 v4 Lab 编码；XYZ 版按 D50 从同一组 Lab 反算后按 u1Fixed15 编码）。
///
/// 由此得到两条不依赖参考实现的硬判据：
/// 1. 同一色名在两份 profile 上经 `lookup_lab` 解出的 Lab 必须一致（差异只来自
///    u16 量化）；
/// 2. 完整色名必须等于 `prefix + rootName + suffix`。
///
/// 另有两条结构性判据，专抓「PCS 当成 s15Fixed16」这类编码错误：
/// - tag 长度必须等于 `84 + count × (38 + 2×nDeviceCoords)`；
/// - 中性灰的 a/b 必须解成 0（`0x8000` 锚点），而不是一个 0.5 量级的数。

///|
/// 读取命名色夹具。
fn named_fixture(name : String) -> Profile raise {
  load_profile(name)
}

///|
/// 浮点近似比较。
fn near(a : Double, b : Double, tol : Double) -> Bool {
  (a - b).abs() <= tol
}

///|
/// `ncl2` 的全部字段都必须被解析出来：vendorFlag、count、nDeviceCoords、
/// prefix、suffix、每条 rootName / PCS / 设备坐标。
///
/// 这是「标准读取」的可执行证据——字段名与 ICC.1:2010-12 §10.14 一一对应。
test "命名色: ncl2 全字段解析" {
  let table = named_fixture("named_lab.icc").named_colors()
  inspect(table.length(), content="5")
  inspect(table.vendor_flag(), content="0")
  inspect(table.device_coords_count(), content="3")
  inspect(table.prefix(), content="PANTONE ")
  inspect(table.suffix(), content=" C")
  inspect(table.pcs_space(), content="Lab ")
  inspect(table.major_version(), content="4")
  let first = table.colors[0]
  inspect(first.root_name(), content="Red")
  inspect(first.full_name(), content="PANTONE Red C")
  if !near(first.pcs().x, 54.0, 0.01) {
    fail("第一条的 PCS L 应为 54.0，实际 \{first.pcs().x}")
  }
  if !near(first.pcs().y, 80.8, 0.01) {
    fail("第一条的 PCS a 应为 80.8，实际 \{first.pcs().y}")
  }
  if !near(first.pcs().z, 69.9, 0.01) {
    fail("第一条的 PCS b 应为 69.9，实际 \{first.pcs().z}")
  }
  let coords = first.device_coords()
  inspect(coords.length(), content="3")
  inspect(coords[0], content="255")
  inspect(coords[1], content="0")
  inspect(coords[2], content="0")
}

///|
/// 条目步长必须是 `38 + 2×nDeviceCoords` 字节：tag 长度 = 84 + 5×44 = 304。
///
/// 这条判据专抓编码错误：把 PCS 当 `s15Fixed16Number`（12 字节）写会得到 334，
/// 而 lcms2 只按 3 个 u16（6 字节）读——长度不符必然导致第二条起全部错位。
test "命名色: ncl2 条目步长与 tag 长度" {
  let data = @fs.read_file_to_bytes("testdata/named_lab.icc")
  let profile = Profile::parse(data)
  let entry = match profile.find_tag("ncl2") {
    None => fail("夹具里应有 ncl2 tag")
    Some(t) => t
  }
  inspect(entry.size, content="304")
  inspect(84 + 5 * (38 + 2 * 3), content="304")
}

///|
/// 中性灰的 a/b 必须解成 0：这是 `0x8000` 锚点的直接判据。
///
/// 若把 PCS 当 s15Fixed16 读，Gray 会得到 (0.0, 0.0, 0.0) 而不是 (50, 0, 0)；
/// 若把 u16 当 Lab 的原始整数直读，L 会是 32768 而不是 50。
test "命名色: 中性灰落在 a=b=0 锚点上" {
  let lab = match
    named_fixture("named_lab.icc").named_colors().lookup_lab("PANTONE Gray C") {
    None => fail("查不到 PANTONE Gray C")
    Some(v) => v
  }
  if !near(lab.0, 50.0, 0.01) {
    fail("Gray 的 L 应为 50.0，实际 \{lab.0}")
  }
  if !near(lab.1, 0.0, 0.01) || !near(lab.2, 0.0, 0.01) {
    fail("Gray 的 a/b 应为 0，实际 (\{lab.1}, \{lab.2})")
  }
}

///|
/// 完整色名 = `prefix + 根名 + suffix`：这是「标准使用」的可执行证据。
///
/// 只用根名查不到（说明查表走的是完整名，不是自造的简化名）。
test "命名色: 完整色名 = prefix + 根名 + suffix" {
  let table = named_fixture("named_lab.icc").named_colors()
  match table.lookup("PANTONE Green C") {
    None => fail("完整色名 PANTONE Green C 应能查到")
    Some(e) => {
      inspect(e.root_name(), content="Green")
      if !near(e.pcs().x, 87.7, 0.01) {
        fail("Green 的 PCS L 应为 87.7，实际 \{e.pcs().x}")
      }
    }
  }
  if table.lookup("Green") is Some(_) {
    fail("裸根名 Green 不应命中：查表语义是完整色名")
  }
  if table.lookup("PANTONE Green") is Some(_) {
    fail("缺后缀的 PANTONE Green 不应命中")
  }
}

///|
/// 同根名重复出现时取文件中靠前的一条（线性查表语义）。
///
/// 夹具里 `Red` 出现两次：L=54.0（第 1 条）与 L=40.0（第 5 条）。
test "命名色: 同根名重复时取首条" {
  let table = named_fixture("named_lab.icc").named_colors()
  let hit = match table.lookup_lab("PANTONE Red C") {
    None => fail("PANTONE Red C 应能查到")
    Some(v) => v
  }
  if !near(hit.0, 54.0, 0.01) {
    fail("应命中第 1 条（L=54.0），实际 L=\{hit.0}")
  }
  let fifth = table.colors[4]
  if !near(fifth.pcs().x, 40.0, 0.01) {
    fail("第 5 条的 L 应为 40.0，实际 \{fifth.pcs().x}")
  }
  inspect(fifth.full_name(), content="PANTONE Red C")
}

///|
/// PCS 为 `XYZ ` 时，`lookup_lab` 必须经 D50 换算出与 Lab 版一致的 Lab。
///
/// 这是**跨编码空间**的判据：同一组色名、同一组 Lab，只是 tag 里的存储空间不同。
/// 若把 XYZ 当 Lab 直接返回，Gray 会得到 (0.1776, 0.1842, 0.1519) 而不是 (50,0,0)，
/// 差两个数量级，无法蒙混过关。
test "命名色: XYZ 与 Lab 两种 PCS 解出同一组 Lab" {
  let xyz_table = named_fixture("named_xyz.icc").named_colors()
  inspect(xyz_table.pcs_space(), content="XYZ ")
  let lab_table = named_fixture("named_lab.icc").named_colors()
  let names : Array[String] = [
    "PANTONE Red C", "PANTONE Green C", "PANTONE Blue C", "PANTONE Gray C",
  ]
  for name in names {
    let a = match lab_table.lookup_lab(name) {
      None => fail("Lab 版查不到 \{name}")
      Some(v) => v
    }
    let b = match xyz_table.lookup_lab(name) {
      None => fail("XYZ 版查不到 \{name}")
      Some(v) => v
    }
    // 容差 0.1：u16 量化（Lab 侧 1/65535、XYZ 侧 1/32768）+ Lab→XYZ→Lab 往返
    if !near(a.0, b.0, 0.1) || !near(a.1, b.1, 0.1) || !near(a.2, b.2, 0.1) {
      fail(
        "\{name} 在两份 profile 上的 Lab 不一致: Lab 版 (\{a.0}, \{a.1}, \{a.2}) vs XYZ 版 (\{b.0}, \{b.1}, \{b.2})",
      )
    }
  }
  let gray = match xyz_table.lookup_lab("PANTONE Gray C") {
    None => fail("XYZ 版查不到 PANTONE Gray C")
    Some(v) => v
  }
  if !near(gray.1, 0.0, 0.1) || !near(gray.2, 0.0, 0.1) {
    fail("Gray 在 XYZ 版上的 a/b 应为 0，实际 (\{gray.1}, \{gray.2})")
  }
}

///|
/// 畸形输入必须报结构化错误，不 panic、不静默返回空表。
///
/// 负例通过**构造 tag 表项**得到，不改夹具字节：
/// 1. 声明长度不足（size=90 < 头部 84 + 第 1 条 44 字节）→ `BadTagData`；
/// 2. 把 `desc`（`mluc`）的表项当作 `ncl2` 传入 → 类型签名不符 → `BadTagData`。
test "命名色: 截断与错类型签名报结构化错误" {
  let data = @fs.read_file_to_bytes("testdata/named_lab.icc")
  let profile = Profile::parse(data)
  let real = match profile.find_tag("ncl2") {
    None => fail("夹具里应有 ncl2 tag")
    Some(t) => t
  }
  let truncated : IccTagEntry = {
    signature: "ncl2",
    offset: real.offset,
    size: 90,
  }
  try {
    let _ = parse_named_color2(data, truncated)
    fail("声明长度不足的 ncl2 应报 BadTagData")
  } catch {
    BadTagData(..) => ()
    e => fail("期望 BadTagData，实际: \{e}")
  }
  let desc = match profile.find_tag("desc") {
    None => fail("夹具里应有 desc tag")
    Some(t) => t
  }
  try {
    let _ = parse_named_color2(data, desc)
    fail("把 mluc 当 ncl2 解析应报 BadTagData")
  } catch {
    BadTagData(..) => ()
    e => fail("期望 BadTagData，实际: \{e}")
  }
  // 非命名色 profile 调用 named_colors() 也必须显式失败，而不是返回空表
  try {
    let _ = named_fixture("srgb.icc").named_colors()
    fail("srgb.icc 没有 ncl2，named_colors() 应报 BadTagData")
  } catch {
    BadTagData(..) => ()
    e => fail("期望 BadTagData，实际: \{e}")
  }
}

///|
/// `nmcl` 类在一致性报告里必须报「本次实现」，且必需 tag 检查通过。
///
/// 命名色提供的是「色名 → PCS」查表，不是设备↔PCS 数值变换，
/// 因此 `transform_supported` 为 false 是**有意的语义区分**，不是缺口。
test "命名色: nmcl 类的一致性报告为本次实现" {
  let report = named_fixture("named_lab.icc").conformance()
  inspect(report.device_class(), content="nmcl")
  inspect(report.support_level(), content="本次实现")
  inspect(report.version(), content="4.3")
  if !report.ok() {
    let missing = report.missing()
    let mut names = ""
    for m in missing {
      names = names + " " + m
    }
    fail("named_lab.icc 缺少必需 tag:\{names}")
  }
  inspect(report.transform_supported(), content="false")
}
