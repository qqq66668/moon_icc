///|
/// ICC 头部与 tag 表解析的测试。
///
/// 判据分两类：
/// 1. **合成字节流**：精确控制每个字段，验证解析逻辑本身；
/// 2. **真实 profile**：本机 Windows 系统自带的 profile，验证能处理真实数据。
///
/// 合成用例里的期望值全部是**手算的十六进制字面量**，不经过被测代码计算。

///|
/// 构造一个最小的合法 profile 字节流。
///
/// 只填充头部与 tag 表，不构造 tag 数据内容（功能 1 不需要）。
fn build_minimal_profile(
  device_class~ : String = "mntr",
  color_space~ : String = "RGB ",
  pcs~ : String = "XYZ ",
  signature~ : String = "acsp",
  tag_count~ : Int32 = 0,
) -> Bytes {
  let buf = @buffer.Buffer()
  let tag_table_size = 4 + tag_count * 12
  let total = 128 + tag_table_size
  // 0..3 size
  buf.write_uint_be(total.reinterpret_as_uint())
  // 4..7 cmmType
  buf.write_uint_be((0 : UInt32))
  // 8..11 version = 2.1.0.0 -> 0x02100000
  buf.write_uint_be((0x02100000 : UInt32))
  // 12..15 deviceClass
  buf.write_bytes(@utf8.encode(device_class))
  // 16..19 colorSpace
  buf.write_bytes(@utf8.encode(color_space))
  // 20..23 pcs
  buf.write_bytes(@utf8.encode(pcs))
  // 24..35 dateTime = 2024-03-08 12:34:56（6 个 u16，共 12 字节）
  buf.write_uint16_be((2024 : UInt32).to_uint16())
  buf.write_uint16_be((3 : UInt32).to_uint16())
  buf.write_uint16_be((8 : UInt32).to_uint16())
  buf.write_uint16_be((12 : UInt32).to_uint16())
  buf.write_uint16_be((34 : UInt32).to_uint16())
  buf.write_uint16_be((56 : UInt32).to_uint16())
  // 36..39 signature
  buf.write_bytes(@utf8.encode(signature))
  // 40..43 platform
  buf.write_bytes(b"MSFT")
  // 44..47 flags
  buf.write_uint_be((0 : UInt32))
  // 48..51 manufacturer
  buf.write_uint_be((0 : UInt32))
  // 52..55 model
  buf.write_uint_be((0 : UInt32))
  // 56..63 attributes (u64)
  buf.write_uint_be((0 : UInt32))
  buf.write_uint_be((0 : UInt32))
  // 64..67 renderingIntent = 1 (relative colorimetric)
  buf.write_uint_be((1 : UInt32))
  // 68..79 illuminant = D50 (0.9642, 1.0, 0.8249)
  //   0.9642 * 65536 = 63190.6 -> 63190 = 0x0000F6D6
  buf.write_uint_be((63190 : UInt32))
  buf.write_uint_be((65536 : UInt32))
  // 0.8249 * 65536 = 54060.6 -> 54061，与真实 sRGB profile 存储值一致
  buf.write_uint_be((54061 : UInt32))
  // 80..83 creator
  buf.write_uint_be((0 : UInt32))
  // 84..99 profileId (16 bytes zero)
  for i = 0; i < 16; i = i + 1 {
    buf.write_byte(b'\x00')
  }
  // 100..127 reserved (28 bytes zero)
  for i = 0; i < 28; i = i + 1 {
    buf.write_byte(b'\x00')
  }
  // 128..131 tagCount
  buf.write_uint_be(tag_count.reinterpret_as_uint())
  buf.to_bytes()
}

///|
/// 头部：固定字段逐项核对。
test "parse_header: 合成最小 profile 的字段" {
  let data = build_minimal_profile()
  let h = parse_header(data)
  inspect(h.size, content="132")
  inspect(h.major_version, content="2")
  inspect(h.minor_version, content="1")
  inspect(h.device_class, content="mntr")
  inspect(h.color_space, content="RGB ")
  inspect(h.pcs, content="XYZ ")
  inspect(h.date_time.to_iso_string(), content="2024-03-08T12:34:56")
  inspect(h.rendering_intent, content="1")
  inspect(
    rendering_intent_name(h.rendering_intent),
    content="relative-colorimetric",
  )
  inspect(h.is_display(), content="true")
}

///|
/// 头部：D50 照明体必须解成 0.9642 / 1.0 / 0.8249。
///
/// 期望值来源：ICC 规范规定 PCS 照明体为 D50，
/// `s15Fixed16(0.9642) = 63190`、`s15Fixed16(0.8249) = 54061`。
/// 54061 这个具体整数值取自真实 sRGB profile 的头部实测（见
/// `真实 profile: sRGB` 一例），不是手算。
test "parse_header: 照明体定点数转换" {
  let data = build_minimal_profile()
  let h = parse_header(data)
  // 63190 / 65536 = 0.964202880859375
  inspect(h.illuminant.x, content="0.964202880859375")
  inspect(h.illuminant.y, content="1")
  // 54061 / 65536 = 0.8249053955078125
  inspect(h.illuminant.z, content="0.8249053955078125")
}

///|
/// 头部：签名不是 `acsp` 必须报错。
test "parse_header: 错误签名被拒绝" {
  let data = build_minimal_profile(signature="XXXX")
  try parse_header(data) catch {
    BadSignature(found~) => inspect(found, content="XXXX")
    e => fail("期望 BadSignature，实际: \{e}")
  } noraise {
    _ => fail("应当因签名错误而失败，实际却通过了")
  }
}

///|
/// 头部：数据不足 128 字节必须报错，且不得 panic。
test "parse_header: 截断数据被拒绝" {
  let data = build_minimal_profile()
  let truncated = data.exact_view(start=0, end=100).to_owned()
  try parse_header(truncated) catch {
    Truncated(..) => ()
    e => fail("期望 Truncated，实际: \{e}")
  } noraise {
    _ => fail("应当因数据截断而失败")
  }
}

///|
/// 头部：空输入必须报错而不是 panic。
test "parse_header: 空输入被拒绝" {
  try parse_header(b"") catch {
    Truncated(..) => ()
    e => fail("期望 Truncated，实际: \{e}")
  } noraise {
    _ => fail("空输入应当被拒绝")
  }
}

///|
/// 构造一个带完整 tag 表的合成 profile。
///
/// `tag_count` 只用于写入头部声明与实际条目数一致的场景；
/// 条目内容由调用方以 `(signature, offset, size)` 给出。
fn build_profile_with_tags(
  tags : Array[(String, Int32, Int32)],
  declared_count~ : Int32 = -1,
) -> Bytes {
  let count = if declared_count < 0 { tags.length() } else { declared_count }
  let buf = @buffer.Buffer()
  // 先留出头部与 tag 表占位，最后回填 size 字段
  let total = 128 + 4 + tags.length() * 12
  buf.write_uint_be(total.reinterpret_as_uint())
  buf.write_uint_be((0 : UInt32))
  buf.write_uint_be((0x02100000 : UInt32))
  buf.write_bytes(b"mntr")
  buf.write_bytes(b"RGB ")
  buf.write_bytes(b"XYZ ")
  for i = 0; i < 6; i = i + 1 {
    buf.write_uint16_be((2024 : UInt32).to_uint16())
  }
  buf.write_bytes(b"acsp")
  buf.write_bytes(b"MSFT")
  // 44..47 flags
  buf.write_uint_be((0 : UInt32))
  // 48..51 manufacturer
  buf.write_uint_be((0 : UInt32))
  // 52..55 model
  buf.write_uint_be((0 : UInt32))
  // 56..63 attributes (u64 = 两个 u32)
  buf.write_uint_be((0 : UInt32))
  buf.write_uint_be((0 : UInt32))
  // 64..67 renderingIntent
  buf.write_uint_be((0 : UInt32))
  // 68..79 illuminant (3 × s15Fixed16)
  buf.write_uint_be((63190 : UInt32))
  buf.write_uint_be((65536 : UInt32))
  buf.write_uint_be((54061 : UInt32))
  // 80..83 creator
  buf.write_uint_be((0 : UInt32))
  // 84..99 profileId (16 bytes)
  for i = 0; i < 16; i = i + 1 {
    buf.write_byte(b'\x00')
  }
  // 100..127 reserved (28 bytes)
  for i = 0; i < 28; i = i + 1 {
    buf.write_byte(b'\x00')
  }
  buf.write_uint_be(count.reinterpret_as_uint())
  for t in tags {
    let (sig, offset, size) = t
    buf.write_bytes(@utf8.encode(sig))
    buf.write_uint_be(offset.reinterpret_as_uint())
    buf.write_uint_be(size.reinterpret_as_uint())
  }
  buf.to_bytes()
}

///|
/// tag 表：条目数正确解出，顺序保持文件原始顺序。
///
/// 偏移刻意落在文件范围内（合成 profile 共 128+4+2×12 = 156 字节，
/// 故偏移取 156 之前的合法值）。越界行为由下一条测试单独覆盖。
test "parse_tag_table: 条目数量与顺序" {
  let data = build_profile_with_tags([("rXYZ", 132, 12), ("gXYZ", 144, 12)])
  let h = parse_header(data)
  let entries = parse_tag_table(data, h)
  inspect(entries.length(), content="2")
  inspect(entries[0].signature, content="rXYZ")
  inspect(entries[0].offset, content="132")
  inspect(entries[0].size, content="12")
  inspect(entries[1].signature, content="gXYZ")
  inspect(entries[1].offset, content="144")
}

///|
/// tag 表：偏移越界必须报错。
test "parse_tag_table: 越界条目被拒绝" {
  // 偏移远超实际长度
  let data = build_profile_with_tags([("rXYZ", 999999, 20)])
  let h = parse_header(data)
  try parse_tag_table(data, h) catch {
    TagOutOfBounds(tag~, ..) => inspect(tag, content="rXYZ")
    e => fail("期望 TagOutOfBounds，实际: \{e}")
  } noraise {
    _ => fail("越界 tag 应当被拒绝")
  }
}

///|
/// tag 表：条目数超出可用空间必须报错。
///
/// 头部声明 1000 个条目，但实际只够 1 个。
test "parse_tag_table: 过量条目被拒绝" {
  let data = build_profile_with_tags([("rXYZ", 200, 20)], declared_count=1000)
  let h = parse_header(data)
  try parse_tag_table(data, h) catch {
    BadTagTable(..) => ()
    e => fail("期望 BadTagTable，实际: \{e}")
  } noraise {
    _ => fail("条目数超出空间应当被拒绝")
  }
}

///|
/// 定点转换：16.16 语义必须精确。
test "定点数转换语义" {
  // 1.0 -> 65536
  inspect(s15f16_to_double(65536), content="1")
  // -1.0 -> -65536
  inspect(s15f16_to_double(-65536), content="-1")
  // 0.5 -> 32768
  inspect(s15f16_to_double(32768), content="0.5")
  // 0 -> 0
  inspect(s15f16_to_double(0), content="0")
}

///|
/// 真实 profile：sRGB（matrix/TRC 型）。
///
/// 期望值来自对同一文件的独立 Python 解析（struct 模块直读），
/// 不是被测代码算出来的。
test "真实 profile: sRGB" {
  let data = @fs.read_file_to_bytes("testdata/srgb.icc")
  let h = parse_header(data)
  inspect(h.size, content="3144")
  inspect(h.major_version, content="2")
  inspect(h.minor_version, content="1")
  inspect(h.device_class, content="mntr")
  inspect(h.color_space, content="RGB ")
  inspect(h.pcs, content="XYZ ")
  inspect(h.date_time.to_iso_string(), content="1998-02-09T06:49:00")
  inspect(h.rendering_intent, content="0")
  inspect(rendering_intent_name(h.rendering_intent), content="perceptual")
  let entries = parse_tag_table(data, h)
  inspect(entries.length(), content="17")
  // 文件中的第一个 tag 是 cprt
  inspect(entries[0].signature, content="cprt")
}

///|
/// 真实 profile：sRGB 必须含 matrix/TRC 所需的全部 tag。
///
/// 这是功能 2 的前置条件：没有 rXYZ/gXYZ/bXYZ 与 rTRC/gTRC/bTRC
/// 就无法做 matrix/TRC 变换。
test "真实 profile: sRGB 含 matrix/TRC 必需 tag" {
  let data = @fs.read_file_to_bytes("testdata/srgb.icc")
  let h = parse_header(data)
  let entries = parse_tag_table(data, h)
  let sigs = entries.map(fn(e) { e.signature })
  for required in ["rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC"] {
    if !sigs.contains(required) {
      fail("sRGB profile 缺少必需 tag: \{required}")
    }
  }
  inspect(sigs.contains("wtpt"), content="true")
}

///|
/// 真实 profile：显示器 profile（21 个 tag）。
test "真实 profile: 显示器 profile" {
  let data = @fs.read_file_to_bytes("testdata/display.icc")
  let h = parse_header(data)
  inspect(h.size, content="20620")
  inspect(h.major_version, content="2")
  inspect(h.minor_version, content="2")
  inspect(h.device_class, content="mntr")
  inspect(h.color_space, content="RGB ")
  let entries = parse_tag_table(data, h)
  inspect(entries.length(), content="21")
}

///|
/// 真实 profile：CMYK 打印机 profile（LUT 型）。
///
/// v1 不实现 LUT 变换，但**必须能正确解析**它的头部与 tag 表，
/// 以便在功能 2 中识别并给出明确错误，而不是静默失败。
test "真实 profile: CMYK 打印机 profile 可解析" {
  let data = @fs.read_file_to_bytes("testdata/cmyk_printer.icc")
  let h = parse_header(data)
  inspect(h.size, content="218103")
  inspect(h.major_version, content="2")
  inspect(h.minor_version, content="0")
  inspect(h.device_class, content="prtr")
  inspect(h.color_space, content="CMYK")
  inspect(h.pcs, content="Lab ")
  inspect(h.is_display(), content="false")
  let entries = parse_tag_table(data, h)
  inspect(entries.length(), content="16")
  let sigs = entries.map(fn(e) { e.signature })
  // 打印机 profile 用 A2B0/B2A0 这类 LUT tag，没有 matrix/TRC
  inspect(sigs.contains("A2B0"), content="true")
  inspect(sigs.contains("rXYZ"), content="false")
}

///|
/// 真实 profile：所有 tag 条目都必须落在文件范围内。
///
/// 这是对边界校验的整体验证，覆盖三个 profile 的全部 tag。
test "真实 profile: 所有 tag 边界合法" {
  for
    file in [
      "testdata/srgb.icc", "testdata/display.icc", "testdata/cmyk_printer.icc",
    ] {
    let data = @fs.read_file_to_bytes(file)
    let h = parse_header(data)
    let entries = parse_tag_table(data, h)
    for e in entries {
      if e.offset < 0 || e.offset + e.size > data.length() {
        fail("\{file} 中 tag \{e.signature} 越界")
      }
    }
  }
}
