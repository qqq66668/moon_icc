///|
/// ICC profile 的大端序二进制读取基座。
///
/// ICC 规范（ISO 15076-1 / ICC.1）全程使用大端序（big-endian）。
/// 本模块只负责"安全读取"：任何越界访问都返回错误而不是 panic，
/// 因为 profile 文件是外部不可信输入。
///
/// 注意：`s15Fixed16Number` 是 16.16 定点数，`u16Fixed16Number` 是 16.16 无符号定点数。
/// 定点转换集中在本模块，避免各处重复实现。

///|
/// 解析过程中可能出现的错误。
pub suberror IccError {
  /// 数据长度不足，无法读取所需字段。
  Truncated(expected~ : Int32, offset~ : Int32, actual~ : Int32)
  /// 文件头签名不是 `acsp`。
  BadSignature(found~ : String)
  /// 声明的 profile 尺寸与实际字节数不一致。
  SizeMismatch(declared~ : Int32, actual~ : Int32)
  /// tag 表中某一项的偏移或长度越界。
  TagOutOfBounds(tag~ : String, offset~ : Int32, size~ : Int32)
  /// tag 表本身越界或条目数不合理。
  BadTagTable(count~ : Int32, offset~ : Int32)
  /// tag 数据的内容不符合其类型要求。
  BadTagData(tag~ : String, reason~ : String)
  /// 数值超出可表示范围（如标签数量过大）。
  OutOfRange(what~ : String, value~ : Int32)
}

///|
/// 大端序读取器：持有一份字节数据与当前游标，所有读取都做边界检查。
///
/// 游标是可变的，读取失败时游标不动，便于调用方决定是否继续。
pub struct BigEndianReader {
  data : Bytes
  mut pos : Int32
}

///|
/// 用给定字节创建读取器，游标从 0 开始。
pub fn BigEndianReader::new(data : Bytes) -> BigEndianReader {
  { data, pos: 0, }
}

///|
/// 剩余可读字节数。
pub fn BigEndianReader::remaining(self : BigEndianReader) -> Int32 {
  self.data.length() - self.pos
}

///|
/// 当前游标位置。
pub fn BigEndianReader::position(self : BigEndianReader) -> Int32 {
  self.pos
}

///|
/// 把游标移动到指定绝对位置。越界返回错误。
pub fn BigEndianReader::seek(
  self : BigEndianReader,
  offset : Int32,
) -> Unit raise IccError {
  if offset < 0 || offset > self.data.length() {
    raise Truncated(expected=4, offset~, actual=self.data.length())
  }
  self.pos = offset
}

///|
/// 跳过若干字节。越界返回错误。
pub fn BigEndianReader::skip(
  self : BigEndianReader,
  n : Int32,
) -> Unit raise IccError {
  if n < 0 {
    raise OutOfRange(what="skip", value=n)
  }
  self.seek(self.pos + n)
}

///|
/// 检查从当前位置起还有 `n` 字节可读，不足则报错。
fn BigEndianReader::ensure(
  self : BigEndianReader,
  n : Int32,
  offset : Int32,
) -> Unit raise IccError {
  if self.pos + n > self.data.length() {
    raise Truncated(expected=n, offset~, actual=self.data.length() - self.pos)
  }
}

///|
/// 读取 1 字节无符号整数。
pub fn BigEndianReader::read_u8(self : BigEndianReader) -> Int32 raise IccError {
  let at = self.pos
  self.ensure(1, at)
  self.pos = at + 1
  self.data[at].to_int()
}

///|
/// 读取 2 字节大端无符号整数。
pub fn BigEndianReader::read_u16(
  self : BigEndianReader,
) -> Int32 raise IccError {
  let at = self.pos
  self.ensure(2, at)
  self.pos = at + 2
  (self.data[at].to_int() << 8) | self.data[at + 1].to_int()
}

///|
/// 读取 4 字节大端无符号整数。
///
/// 返回 `Int`：ICC 中 32 位字段（偏移、长度、tag 数量）都在 Int 可表示范围内。
/// 若最高位被置位导致解释为负数，说明数据畸形，这里显式拒绝。
pub fn BigEndianReader::read_u32(
  self : BigEndianReader,
) -> Int32 raise IccError {
  let at = self.pos
  self.ensure(4, at)
  self.pos = at + 4
  let hi = (self.data[at].to_int() << 24) |
    (self.data[at + 1].to_int() << 16) |
    (self.data[at + 2].to_int() << 8) |
    self.data[at + 3].to_int()
  if hi < 0 {
    raise OutOfRange(what="u32", value=hi)
  }
  hi
}

///|
/// 读取 4 字节大端有符号整数。
pub fn BigEndianReader::read_s32(
  self : BigEndianReader,
) -> Int32 raise IccError {
  let at = self.pos
  self.ensure(4, at)
  self.pos = at + 4
  let hi = (self.data[at].to_int() << 24) |
    (self.data[at + 1].to_int() << 16) |
    (self.data[at + 2].to_int() << 8) |
    self.data[at + 3].to_int()
  hi
}

///|
/// 读取 8 字节大端无符号整数（ICC 的 dateTimeNumber 等场景用不到，
/// 但 profile 里 `u64` 字段偶有出现）。超过 2^53 会丢失精度，此处显式拒绝。
pub fn BigEndianReader::read_u64(
  self : BigEndianReader,
) -> Int32 raise IccError {
  let hi = self.read_u32()
  let lo = self.read_u32()
  if hi > 0x1F_FFFF {
    raise OutOfRange(what="u64", value=hi)
  }
  (hi << 32) | lo
}

///|
/// 读取 4 字节 ASCII 签名（如 `acsp`、`mntr`、`XYZ `）。
///
/// 签名来自外部不可信输入，可能含 NUL 等不可打印字节。这类字节若原样进入
/// 错误消息，会让日志与测试驱动无法解析（本项目真实踩到过：一个畸形的内嵌
/// 曲线签名 `\0\0cu` 导致测试结果的 JSON 解析失败）。因此这里把
/// 可打印 ASCII 之外的字节统一渲染成 `.`——合法签名全部是可打印 ASCII，
/// 该替换不影响任何查表语义。
pub fn BigEndianReader::read_signature(
  self : BigEndianReader,
) -> String raise IccError {
  let at = self.pos
  self.ensure(4, at)
  self.pos = at + 4
  let buf = StringBuilder()
  for i = 0; i < 4; i = i + 1 {
    let b = self.data[at + i].to_int()
    if b >= 32 && b < 127 {
      buf.write_char(b.unsafe_to_char())
    } else {
      buf.write_char('.')
    }
  }
  buf.to_string()
}

///|
/// 读取 `s15Fixed16Number`：有符号 16.16 定点数。
pub fn BigEndianReader::read_s15f16(
  self : BigEndianReader,
) -> Double raise IccError {
  self.read_s32().to_double() / 65536.0
}

///|
/// 读取 `u16Fixed16Number`：无符号 16.16 定点数。
pub fn BigEndianReader::read_u16f16(
  self : BigEndianReader,
) -> Double raise IccError {
  self.read_u32().to_double() / 65536.0
}

///|
/// 读取 `u8Fixed8Number`：无符号 8.8 定点数。
pub fn BigEndianReader::read_u8f8(
  self : BigEndianReader,
) -> Double raise IccError {
  self.read_u16().to_double() / 256.0
}

///|
/// 从当前位置复制 `n` 字节。越界返回错误。
pub fn BigEndianReader::read_bytes(
  self : BigEndianReader,
  n : Int32,
) -> Bytes raise IccError {
  if n < 0 {
    raise OutOfRange(what="read_bytes", value=n)
  }
  let at = self.pos
  self.ensure(n, at)
  self.pos = at + n
  let buf = @buffer.Buffer()
  for i = 0; i < n; i = i + 1 {
    buf.write_byte(self.data[at + i])
  }
  buf.to_bytes()
}

///|
impl Show for IccError with fn output(self, logger) {
  match self {
    Truncated(expected~, offset~, actual~) =>
      logger.write(
        "IccError::Truncated(期望 \{expected} 字节, 偏移 \{offset}, 实际剩余 \{actual})",
      )
    BadSignature(found~) =>
      logger.write(
        "IccError::BadSignature(找到 \"\{found}\", 期望 \"acsp\")",
      )
    SizeMismatch(declared~, actual~) =>
      logger.write(
        "IccError::SizeMismatch(声明 \{declared}, 实际 \{actual})",
      )
    TagOutOfBounds(tag~, offset~, size~) =>
      logger.write(
        "IccError::TagOutOfBounds(tag \"\{tag}\", 偏移 \{offset}, 长度 \{size})",
      )
    BadTagTable(count~, offset~) =>
      logger.write(
        "IccError::BadTagTable(\{count} 个条目, 表偏移 \{offset})",
      )
    BadTagData(tag~, reason~) =>
      logger.write("IccError::BadTagData(tag \"\{tag}\": \{reason})")
    OutOfRange(what~, value~) =>
      logger.write("IccError::OutOfRange(\{what} = \{value})")
  }
}

///|
/// 把 `s15Fixed16Number` 的原始 32 位整数转为浮点。
///
/// 单独暴露是为了让测试能直接验证 16.16 定点语义，
/// 而不必构造完整 profile。
pub fn s15f16_to_double(raw : Int32) -> Double {
  raw.to_double() / 65536.0
}

///|
/// 把 `u16Fixed16Number` 的原始 32 位整数转为浮点。
pub fn u16f16_to_double(raw : Int32) -> Double {
  raw.to_double() / 65536.0
}
