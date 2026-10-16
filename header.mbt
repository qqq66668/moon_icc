///|
/// ICC profile 头部（128 字节）与 tag 表的解析。
///
/// 布局依据 ICC.1:2022 / ISO 15076-1 第 7 章。全部字段为大端序。
///
/// 头部偏移表（字节）：
///   0   size            u32     profile 总字节数
///   4   cmmType         u32     preferred CMM（0 表示未指定，无约束）
///   8   version         u32     (major.4)(minor.4)(bug.4)(reserved.4)
///   12  deviceClass     4 字节  'scnr'/'mntr'/'prtr'/'link'/'spac'/'abst'/'nmcl'
///   16  colorSpace      4 字节  输入色空间，如 'RGB '/'CMYK'/'GRAY'/'Lab '
///   20  pcs             4 字节  'XYZ ' 或 'Lab '
///   24  dateTime        12 字节 6×u16: 年/月/日/时/分/秒
///   36  signature       4 字节  必须是 'acsp'
///   40  platform        4 字节
///   44  flags           u32
///   48  manufacturer    u32
///   52  model           u32
///   56  attributes      u64
///   64  renderingIntent u32
///   68  illuminant      12 字节 3×s15Fixed16 (PCS 白点, 通常 D50)
///   80  creator         u32
///   84  profileId       16 字节 (MD5, 可为全 0)
///   100 reserved        28 字节
///   128 tagCount        u32
///   132 tagTable        tagCount × 12 字节 {sig:4, offset:u32, size:u32}

///|
/// 头部固定长度。
pub let header_size : Int32 = 128

///|
/// 每个 tag 表项固定长度。
pub let tag_entry_size : Int32 = 12

///|
/// `acsp` 文件签名。
pub let icc_signature : String = "acsp"

///|
/// profile 的日期时间字段（6 个 u16）。
pub struct IccDateTime {
  year : Int32
  month : Int32
  day : Int32
  hour : Int32
  minute : Int32
  second : Int32
}

///|
/// 用 ISO 8601 风格格式化日期时间。
pub fn IccDateTime::to_iso_string(self : IccDateTime) -> String {
  let two = fn(n : Int32) -> String {
    if n < 10 {
      "0" + n.to_string()
    } else {
      n.to_string()
    }
  }
  self.year.to_string() +
  "-" +
  two(self.month) +
  "-" +
  two(self.day) +
  "T" +
  two(self.hour) +
  ":" +
  two(self.minute) +
  ":" +
  two(self.second)
}

///|
/// 三刺激值（XYZ 或 Lab 的三分量）。
pub struct XyzNumber {
  x : Double
  y : Double
  z : Double
}

///|
/// 解析后的 profile 头部。
pub struct IccHeader {
  /// 声明的 profile 总字节数。
  size : Int32
  /// preferred CMM 类型（0 表示未指定）。
  cmm_type : Int32
  /// 主版本号。
  major_version : Int32
  /// 次版本号。
  minor_version : Int32
  /// profile 类别，如 `mntr`。
  device_class : String
  /// 输入色空间，如 `RGB `。
  color_space : String
  /// PCS，`XYZ ` 或 `Lab `。
  pcs : String
  /// 创建时间。
  date_time : IccDateTime
  /// 平台签名。
  platform : String
  /// 标志位。
  flags : Int32
  /// 制造商签名。
  manufacturer : Int32
  /// 设备型号。
  model : Int32
  /// 设备属性（u64，见 ICC.1 表 21）。
  attributes : Int32
  /// 默认渲染意图。
  rendering_intent : Int32
  /// PCS 照明体（通常 D50）。
  illuminant : XyzNumber
  /// 创建者签名。
  creator : Int32
  /// profile ID（16 字节 MD5，可为全 0）。
  profile_id : Bytes
}

///|
/// tag 表中的一个条目。
pub struct IccTagEntry {
  /// tag 签名，如 `rXYZ`。
  signature : String
  /// 相对文件起始的偏移。
  offset : Int32
  /// 数据字节数（含 4 字节类型签名与 4 字节保留位）。
  size : Int32
}

///|
/// 渲染意图的可读名称。未知值返回 `"unknown"`。
pub fn rendering_intent_name(intent : Int32) -> String {
  match intent {
    0 => "perceptual"
    1 => "relative-colorimetric"
    2 => "saturation"
    3 => "absolute-colorimetric"
    _ => "unknown"
  }
}

///|
/// 设备类别为显示器时返回 true。
pub fn IccHeader::is_display(self : IccHeader) -> Bool {
  self.device_class == "mntr"
}

///|
/// 解析 128 字节头部。
///
/// 会校验 `acsp` 签名；`size` 与实际字节数不一致时报 `SizeMismatch`
/// （某些第三方 profile 会留空洞，故仅对"声明值小于实际值"严格报错，
/// 见下方注释）。
pub fn parse_header(data : Bytes) -> IccHeader raise IccError {
  if data.length() < header_size {
    raise Truncated(expected=header_size, offset=0, actual=data.length())
  }
  let r = BigEndianReader::new(data)
  let size = r.read_u32()
  // 声明尺寸可以小于实际文件（尾部填充），但不可大于实际数据，
  // 否则后续 tag 偏移都不可信。
  if size > data.length() {
    raise SizeMismatch(declared=size, actual=data.length())
  }
  let cmm_type = r.read_u32()
  let version = r.read_u32()
  let major_version = (version >> 24) & 0xFF
  let minor_version = (version >> 20) & 0x0F
  let device_class = r.read_signature()
  let color_space = r.read_signature()
  let pcs = r.read_signature()
  let date_time = {
    let year = r.read_u16()
    let month = r.read_u16()
    let day = r.read_u16()
    let hour = r.read_u16()
    let minute = r.read_u16()
    let second = r.read_u16()
    { year, month, day, hour, minute, second, }
  }
  let signature = r.read_signature()
  if signature != icc_signature {
    raise BadSignature(found=signature)
  }
  let platform = r.read_signature()
  let flags = r.read_u32()
  let manufacturer = r.read_u32()
  let model = r.read_u32()
  let attributes = r.read_u64()
  let rendering_intent = r.read_u32()
  let illuminant = {
    let x = r.read_s15f16()
    let y = r.read_s15f16()
    let z = r.read_s15f16()
    { x, y, z, }
  }
  let creator = r.read_u32()
  let profile_id = r.read_bytes(16)
  // 100..128 为 28 字节保留区，按规范必须为 0；此处不强制校验，
  // 因为存在未清零的历史 profile，强制校验会拒掉合法文件。
  {
    size,
    cmm_type,
    major_version,
    minor_version,
    device_class,
    color_space,
    pcs,
    date_time,
    platform,
    flags,
    manufacturer,
    model,
    attributes,
    rendering_intent,
    illuminant,
    creator,
    profile_id,
  }
}

///|
/// 解析 tag 表。
///
/// 每个条目的 `offset + size` 必须落在 profile 数据范围内，否则报
/// `TagOutOfBounds`。返回的条目顺序保持文件中的原始顺序。
pub fn parse_tag_table(
  data : Bytes,
  header : IccHeader,
) -> Array[IccTagEntry] raise IccError {
  let table_start = header_size
  if data.length() < table_start + 4 {
    raise Truncated(
      expected=4,
      offset=table_start,
      actual=data.length() - table_start,
    )
  }
  let r = BigEndianReader::new(data)
  r.seek(table_start)
  let count = r.read_u32()
  // 每个条目 12 字节，条目数必须能装进剩余空间。
  let need = count * tag_entry_size
  if count < 0 || need / tag_entry_size != count {
    raise OutOfRange(what="tag_count", value=count)
  }
  let available = data.length() - (table_start + 4)
  if need > available {
    raise BadTagTable(count~, offset=table_start + 4)
  }
  let entries : Array[IccTagEntry] = []
  for i = 0; i < count; i = i + 1 {
    let signature = r.read_signature()
    let offset = r.read_u32()
    let size = r.read_u32()
    // 越界检查以"声明尺寸"为准：某些 profile 的 size 字段会大于实际文件，
    // 此时用实际可用长度做上界，避免把合法文件误判为损坏。
    let limit = if header.size < data.length() {
      header.size
    } else {
      data.length()
    }
    if offset < 0 || size < 0 || offset + size > limit {
      raise TagOutOfBounds(tag=signature, offset~, size~)
    }
    entries.push({ signature, offset, size, })
  }
  entries
}
