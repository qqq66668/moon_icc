///|
/// 命名色（`ncl2` / namedColor2Type）的解析与查询。
///
/// 依据 ICC.1:2010-12（ISO 15076-1:2010）§10.14（namedColor2Type），以及
/// 表 17–23 中 `nmcl` 设备类对 `ncl2` 的必需要求。
///
/// tag 数据布局（大端序，偏移相对 tag 数据起始）：
///
/// ```
///   0    4   'ncl2'          类型签名
///   4    4   保留位（规范要求为 0）
///   8    4   vendorFlag      厂商自定义标志
///   12   4   count           命名色条数
///   16   4   nDeviceCoords   每条附带的设备坐标个数（0..8）
///   20   32  prefix          色名前缀（ASCII，尾部 0x00 填充）
///   52   32  suffix          色名后缀（ASCII，尾部 0x00 填充）
///   84   ..  count 个条目，每个 `38 + 2*nDeviceCoords` 字节：
///              32 字节 rootName（ASCII，尾部 0x00 填充）
///              3 × uInt16Number     PCS 坐标
///              nDeviceCoords × u16  设备坐标
/// ```
///
/// **PCS 坐标是 3 个 `uInt16Number`，不是 `s15Fixed16Number`**：与 LUT 里的
/// PCS 值同一种编码（Lab：L 0..100 ↔ 0..0xFFFF、a/b -128..127 ↔ 0..0xFFFF，
/// v2 的 16 位上限是 `0xFF00`；XYZ：`u1Fixed15Number`，1.0 ↔ `0x8000`）。
/// 本实现第一版按 `s15Fixed16Number` 写过一次，被 lcms2 的 `cmsNamedColorInfo`
/// 当场否掉（第一条正常、第二条起全部错位）——这条注释是实测结论，不是推断。
///
/// **完整色名 = prefix + rootName + suffix**：规范对色名的定义如此。查表用完整
/// 色名才能区分同根名、不同后缀的条目（`PANTONE Red C` 与 `PANTONE Red U`）。

///|
/// `ncl2` 固定头部字节数：签名 4 + 保留 4 + vendorFlag 4 + count 4 +
/// nDeviceCoords 4 + prefix 32 + suffix 32。
let named_color2_header_size : Int32 = 84

///|
/// 每条命名色的固定字节数：根名 32 + PCS 3×u16（6 字节）。
let named_color2_entry_base : Int32 = 38

///|
/// 规范允许的最大设备坐标个数（ICC.1:2010-12 §10.14）。
let named_color2_max_device_coords : Int32 = 8

///|
/// 一条命名色记录。
///
/// `pcs` 已按 profile 的 PCS 字段与版本解码：PCS 为 `Lab ` 时是
/// L(0..100)/a(-128..127)/b(-128..127)，为 `XYZ ` 时是 XYZ 三刺激值。
pub struct NamedColorEntry {
  /// tag 里的 32 字节根名（已去尾部 0x00）。
  root_name : String
  /// 完整色名：`prefix + root_name + suffix`。
  full_name : String
  /// 解码后的 PCS 三分量。
  pcs : XyzNumber
  /// 附带的设备坐标（个数由 `nDeviceCoords` 决定，可为空）。
  device_coords : Array[Int32]
}

///|
/// 解析后的 `ncl2` tag。
pub struct NamedColor2 {
  /// 厂商自定义标志（`vendorFlag`）。
  vendor_flag : Int32
  /// 色名前缀（已去尾部 0x00）。
  prefix : String
  /// 色名后缀（已去尾部 0x00）。
  suffix : String
  /// 每条附带的设备坐标个数（`nDeviceCoords`）。
  device_coords_count : Int32
  /// profile 头部声明的 PCS（`Lab ` / `XYZ `）；空串表示解析时未提供。
  pcs_space : String
  /// profile 头部的主版本号（决定 Lab 的 16 位上限：v2 用 0xFF00）。
  major_version : Int32
  /// 命名色条目，顺序与文件中一致。
  colors : Array[NamedColorEntry]
}

///|
/// 读取固定长度的 ASCII 名字段（`prefix`/`suffix`/`rootName`）。
///
/// 规范约定这些字段以 0x00 填充到固定长度。这里**无论是否遇到 0x00 都要消费
/// 满 `n` 字节**（否则后续字段全部错位），只把第一个 0x00 之前的内容当作名字。
/// 与 `read_signature` 一致，可打印 ASCII 之外的字节渲染成 `.`，避免畸形输入
/// 里的控制字符进入日志。
fn read_fixed_ascii(r : BigEndianReader, n : Int32) -> String raise IccError {
  let buf = StringBuilder()
  let mut terminated = false
  for i = 0; i < n; i = i + 1 {
    let b = r.read_u8()
    if b == 0 {
      terminated = true
    } else if !terminated {
      if b >= 32 && b < 127 {
        buf.write_char(b.unsafe_to_char())
      } else {
        buf.write_char('.')
      }
    }
  }
  buf.to_string()
}

///|
/// 把 tag 里的 3 个 `uInt16Number` 解码为 PCS 三分量。
///
/// - `Lab `：v4 上限 `0xFFFF`、v2 上限 `0xFF00`；
/// - `XYZ `：`u1Fixed15Number`，1.0 ↔ `0x8000`；
/// - 其他 PCS：原样保留 u16 数值（不猜空间），此时 `lookup_lab` 返回 `None`。
fn decode_named_pcs(
  raw0 : Int32,
  raw1 : Int32,
  raw2 : Int32,
  pcs_space : String,
  major_version : Int32,
) -> XyzNumber {
  match pcs_space {
    "Lab " => {
      let scale = if major_version < 4 { 65280.0 } else { 65535.0 }
      XyzNumber::{
        x: raw0.to_double() / scale * 100.0,
        y: raw1.to_double() / scale * 255.0 - 128.0,
        z: raw2.to_double() / scale * 255.0 - 128.0,
      }
    }
    "XYZ " =>
      XyzNumber::{
        x: raw0.to_double() / 32768.0,
        y: raw1.to_double() / 32768.0,
        z: raw2.to_double() / 32768.0,
      }
    _ =>
      XyzNumber::{
        x: raw0.to_double(),
        y: raw1.to_double(),
        z: raw2.to_double(),
      }
  }
}

///|
/// 解析 `ncl2` tag，并记录 profile 的 PCS 字段与主版本（决定 Lab 解码口径）。
fn parse_named_color2_as(
  data : Bytes,
  entry : IccTagEntry,
  pcs_space : String,
  major_version : Int32,
) -> NamedColor2 raise IccError {
  let (type_sig, body_at) = tag_type_and_data(data, entry)
  if type_sig != "ncl2" {
    raise BadTagData(
      tag=entry.signature,
      reason="期望类型 \"ncl2\"，实际 \"\{type_sig}\"",
    )
  }
  if entry.size < named_color2_header_size {
    raise BadTagData(
      tag=entry.signature,
      reason="tag 只有 \{entry.size} 字节，不足以容纳 \{named_color2_header_size} 字节头部",
    )
  }
  let r = BigEndianReader::new(data)
  r.seek(body_at)
  let vendor_flag = r.read_u32()
  let count = r.read_u32()
  let n_coords = r.read_u32()
  if n_coords > named_color2_max_device_coords {
    raise BadTagData(
      tag=entry.signature,
      reason="nDeviceCoords = \{n_coords} 超出规范允许的 0..\{named_color2_max_device_coords}",
    )
  }
  let prefix = read_fixed_ascii(r, 32)
  let suffix = read_fixed_ascii(r, 32)
  // 条目必须整体落在本 tag 声明的范围内：用除法而不是乘法做上界判断，
  // 避免 count * entry_size 在 Int32 上溢出后绕过检查。
  let tag_end = entry.offset + entry.size
  let available = tag_end - r.position()
  let entry_size = named_color2_entry_base + 2 * n_coords
  if available < 0 || count > available / entry_size {
    raise BadTagData(
      tag=entry.signature,
      reason="声明 \{count} 条命名色（每条 \{entry_size} 字节），但 tag 内只剩 \{available} 字节",
    )
  }
  let colors : Array[NamedColorEntry] = []
  for i = 0; i < count; i = i + 1 {
    let root_name = read_fixed_ascii(r, 32)
    let raw0 = r.read_u16()
    let raw1 = r.read_u16()
    let raw2 = r.read_u16()
    let pcs = decode_named_pcs(raw0, raw1, raw2, pcs_space, major_version)
    let device_coords : Array[Int32] = []
    for k = 0; k < n_coords; k = k + 1 {
      device_coords.push(r.read_u16())
    }
    colors.push({
      root_name,
      full_name: prefix + root_name + suffix,
      pcs,
      device_coords,
    })
  }
  {
    vendor_flag,
    prefix,
    suffix,
    device_coords_count: n_coords,
    pcs_space,
    major_version,
    colors,
  }
}

///|
/// 解析 `ncl2` tag（不提供 profile 的 PCS 与版本：PCS 记为空串、按 v4 解码）。
///
/// 一般通过 `Profile::named_colors` 调用，那里会带上头部的 PCS 与主版本，
/// 使 `lookup_lab` 能把 PCS 正确解释成 Lab。
pub fn parse_named_color2(
  data : Bytes,
  entry : IccTagEntry,
) -> NamedColor2 raise IccError {
  parse_named_color2_as(data, entry, "", 4)
}

///|
/// 读取该 profile 的命名色表（`ncl2` tag）。
///
/// 命名色 profile（设备类 `nmcl`）的必需行为就是这张表：色名 → PCS 查表。
/// 缺少 `ncl2` 的 profile 会报 `BadTagData`，不静默返回空表。
pub fn Profile::named_colors(self : Profile) -> NamedColor2 raise IccError {
  match self.find_tag("ncl2") {
    Some(t) =>
      parse_named_color2_as(
        self.data,
        t,
        self.header.pcs,
        self.header.major_version,
      )
    None =>
      raise BadTagData(
        tag="ncl2",
        reason="profile 中没有 ncl2 tag（不是命名色 profile）",
      )
  }
}

///|
/// 命名色条数。
pub fn NamedColor2::length(self : NamedColor2) -> Int32 {
  self.colors.length()
}

///|
/// 色名前缀（`prefix`）。
pub fn NamedColor2::prefix(self : NamedColor2) -> String {
  self.prefix
}

///|
/// 色名后缀（`suffix`）。
pub fn NamedColor2::suffix(self : NamedColor2) -> String {
  self.suffix
}

///|
/// 厂商自定义标志（`vendorFlag`）。
pub fn NamedColor2::vendor_flag(self : NamedColor2) -> Int32 {
  self.vendor_flag
}

///|
/// 每条命名色附带的设备坐标个数（`nDeviceCoords`）。
pub fn NamedColor2::device_coords_count(self : NamedColor2) -> Int32 {
  self.device_coords_count
}

///|
/// profile 头部声明的 PCS（`Lab ` / `XYZ `；空串表示解析时未提供）。
pub fn NamedColor2::pcs_space(self : NamedColor2) -> String {
  self.pcs_space
}

///|
/// 解码时使用的主版本号（决定 Lab 的 16 位上限）。
pub fn NamedColor2::major_version(self : NamedColor2) -> Int32 {
  self.major_version
}

///|
/// 按序号取条目；越界返回 `None`。
pub fn NamedColor2::entry_at(
  self : NamedColor2,
  index : Int32,
) -> NamedColorEntry? {
  if index < 0 || index >= self.colors.length() {
    return None
  }
  Some(self.colors[index])
}

///|
/// 按**完整色名**（`prefix + 根名 + suffix`）查表，返回第一条匹配项。
///
/// 匹配是 ASCII 精确比较（区分大小写）：`ncl2` 的色名按规范是 ASCII 且以固定
/// 长度存储，规范未定义大小写折叠规则，因此这里不做折叠，避免自造语义。
/// 同根名重复出现时取文件中靠前的一条（与线性查表语义一致）。
pub fn NamedColor2::lookup(
  self : NamedColor2,
  full_name : String,
) -> NamedColorEntry? {
  for c in self.colors {
    if c.full_name == full_name {
      return Some(c)
    }
  }
  None
}

///|
/// 按完整色名查表并返回 PCS 的 **Lab** 表示（L 0..100、a/b -128..127）。
///
/// PCS 为 `Lab ` 时原样返回；为 `XYZ ` 时经 `xyz_to_lab` 转换。
/// `pcs_space` 未知（空串）或既非 Lab 也非 XYZ 时返回 `None`——
/// 不猜一个空间出来，避免给出错误颜色。
pub fn NamedColor2::lookup_lab(
  self : NamedColor2,
  full_name : String,
) -> (Double, Double, Double)? {
  match self.lookup(full_name) {
    None => None
    Some(e) =>
      if self.pcs_space == "Lab " {
        Some((e.pcs.x, e.pcs.y, e.pcs.z))
      } else if self.pcs_space == "XYZ " {
        let lab = xyz_to_lab(e.pcs)
        Some((lab.l, lab.a, lab.b))
      } else {
        None
      }
  }
}

///|
/// 根名（tag 里的 32 字节名字段，不含前缀与后缀）。
pub fn NamedColorEntry::root_name(self : NamedColorEntry) -> String {
  self.root_name
}

///|
/// 完整色名：`prefix + root_name + suffix`。
pub fn NamedColorEntry::full_name(self : NamedColorEntry) -> String {
  self.full_name
}

///|
/// 解码后的 PCS 三分量。
pub fn NamedColorEntry::pcs(self : NamedColorEntry) -> XyzNumber {
  self.pcs
}

///|
/// 附带的设备坐标（可能为空）。
pub fn NamedColorEntry::device_coords(self : NamedColorEntry) -> Array[Int32] {
  self.device_coords
}
