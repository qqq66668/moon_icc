///|
/// matrix/TRC 变换与 Lab 转换的测试。
///
/// 所有期望值均由**独立的 Python 实现**（`tools/diff_oracle.py` 中的同一套逻辑，
/// 直接按 ICC.1 规范读字节）算出后复制到此，不是被测代码的输出。
///
/// 判据设计要点：
/// - **必须包含中间调样本**。TRC 与矩阵顺序颠倒时，黑白点仍然完全正确
///   （0 变换后是 0，1 变换后仍是 D50 白点），只有中间调会错。
///   因此 `to_pcs` 的中间调用例是唯一能钉住顺序的判据。

///|
/// sRGB profile 解出的矩阵列（独立 Python 解析所得）。
///
/// 注意白点：`wtpt` 是 D65 (0.9505, 1.0, 1.0891)，而矩阵列**已经**是
/// 从 D65 经 Bradford 适应到 D50 的结果——所以变换后 (1,1,1) 得到的是
/// 约 (0.9643, 1.0000, 0.8251)，接近 D50，而不是 D65。
test "matrix_trc: 从真实 sRGB profile 解出矩阵列" {
  let data = @fs.read_file_to_bytes("testdata/srgb.icc")
  let profile = Profile::parse(data)
  let t = profile.matrix_trc()
  // rXYZ = (28578, 14581, 912) / 65536
  inspect(t.matrix.col0.x, content="0.436065673828125")
  inspect(t.matrix.col0.y, content="0.2224884033203125")
  inspect(t.matrix.col0.z, content="0.013916015625")
  // gXYZ = (25241, 46981, 6362) / 65536
  inspect(t.matrix.col1.x, content="0.3851470947265625")
  inspect(t.matrix.col1.y, content="0.7168731689453125")
  inspect(t.matrix.col1.z, content="0.097076416015625")
  // bXYZ = (9376, 3972, 46799) / 65536
  inspect(t.matrix.col2.x, content="0.14306640625")
  inspect(t.matrix.col2.y, content="0.06060791015625")
  inspect(t.matrix.col2.z, content="0.7140960693359375")
}

///|
/// TRC：sRGB profile 用的是 1024 项查找表。
test "matrix_trc: TRC 是 1024 项查找表" {
  let data = @fs.read_file_to_bytes("testdata/srgb.icc")
  let profile = Profile::parse(data)
  let t = profile.matrix_trc()
  match t.trc_r {
    Table(items) => inspect(items.length(), content="1024")
    _ => fail("sRGB 的 rTRC 应当是查找表")
  }
}

///|
/// **关键判据**：中间调样本。
///
/// 这组期望值来自独立 Python 实现。它们能钉住 TRC 与矩阵的先后顺序：
/// 若把顺序颠倒（先乘矩阵再套 TRC），黑白点仍对，但这几个值会明显偏离。
test "to_pcs: 中间调样本（钉住 TRC/矩阵顺序）" {
  let data = @fs.read_file_to_bytes("testdata/srgb.icc")
  let profile = Profile::parse(data)
  let t = profile.matrix_trc()
  // v = 0.25
  let p25 = t.to_pcs(0.25, 0.25, 0.25)
  inspect(p25.x, content="0.049063689759460294")
  inspect(p25.y, content="0.050879655743278275")
  inspect(p25.z, content="0.041981500061132944")
  // v = 0.5 —— 恰好是 sRGB 编码的中灰
  let p50 = t.to_pcs(0.5, 0.5, 0.5)
  inspect(p50.x, content="0.20640003241890215")
  inspect(p50.y, content="0.21403939749252843")
  inspect(p50.z, content="0.17660683523992873")
  // v = 0.75
  let p75 = t.to_pcs(0.75, 0.75, 0.75)
  inspect(p75.x, content="0.5038610664868852")
  inspect(p75.y, content="0.5225101848429707")
  inspect(p75.z, content="0.431130302209753")
}

///|
/// 黑白点：这两点即使顺序颠倒也仍然正确，所以它们**不是**顺序判据，
/// 但能验证端点行为与数值边界。
test "to_pcs: 黑点与白点" {
  let data = @fs.read_file_to_bytes("testdata/srgb.icc")
  let profile = Profile::parse(data)
  let t = profile.matrix_trc()
  let black = t.to_pcs(0.0, 0.0, 0.0)
  inspect(black.x, content="0")
  inspect(black.y, content="0")
  inspect(black.z, content="0")
  // 白点：矩阵列之和，接近 D50 而非 D65
  let white = t.to_pcs(1.0, 1.0, 1.0)
  inspect(white.x, content="0.9642791748046875")
  inspect(white.y, content="0.999969482421875")
  inspect(white.z, content="0.8250885009765625")
}

///|
/// 白点验证：变换结果必须接近 D50，而不是 D65。
///
/// 如果实现里错误地额外做了一次色适应（或根本没做），
/// 白点会跑到 D65 (0.9505, 1.0, 1.0891) 附近，此判据即变红。
test "to_pcs: 白点接近 D50 而非 D65" {
  let data = @fs.read_file_to_bytes("testdata/srgb.icc")
  let profile = Profile::parse(data)
  let t = profile.matrix_trc()
  let white = t.to_pcs(1.0, 1.0, 1.0)
  let de = delta_e76(xyz_to_lab(white), xyz_to_lab(d50_white))
  // 与 D50 的色差应当很小（矩阵是按 D50 适应过的）
  if de > 1.0 {
    fail(
      "白点与 D50 的色差 \{de} 过大，可能多加或漏了色适应",
    )
  }
  // 与 D65 应当明显更远
  let d65 = XyzNumber::{ x: 0.9505, y: 1.0, z: 1.0891, }
  let de65 = delta_e76(xyz_to_lab(white), xyz_to_lab(d65))
  if de65 <= de {
    fail("白点更接近 D65 而不是 D50，色适应处理有误")
  }
}

///|
/// 通道独立性：只给红通道时，结果应当等于矩阵的第一列。
test "to_pcs: 纯红通道等于矩阵第一列" {
  let data = @fs.read_file_to_bytes("testdata/srgb.icc")
  let profile = Profile::parse(data)
  let t = profile.matrix_trc()
  let red = t.to_pcs(1.0, 0.0, 0.0)
  inspect(red.x, content="0.436065673828125")
  inspect(red.y, content="0.2224884033203125")
  inspect(red.z, content="0.013916015625")
}

///|
/// XYZ ↔ Lab 往返必须精确可逆。
test "Lab: 往返变换" {
  for
    xyz in [
      XyzNumber::{ x: 0.9642, y: 1.0, z: 0.8249, },
      XyzNumber::{ x: 0.0, y: 0.0, z: 0.0, },
      XyzNumber::{ x: 0.5, y: 0.4, z: 0.3, },
      XyzNumber::{ x: 0.01, y: 0.02, z: 0.03, },
    ] {
    let lab = xyz_to_lab(xyz)
    let back = lab_to_xyz(lab)
    let dx = if back.x - xyz.x < 0.0 { xyz.x - back.x } else { back.x - xyz.x }
    let dy = if back.y - xyz.y < 0.0 { xyz.y - back.y } else { back.y - xyz.y }
    let dz = if back.z - xyz.z < 0.0 { xyz.z - back.z } else { back.z - xyz.z }
    if dx > 1.0e-12 || dy > 1.0e-12 || dz > 1.0e-12 {
      fail("往返误差过大: d=(\{dx}, \{dy}, \{dz})")
    }
  }
}

///|
/// D50 白点的 Lab 必须正好是 (100, 0, 0)。
test "Lab: D50 白点映射到 L=100 a=0 b=0" {
  let lab = xyz_to_lab(d50_white)
  inspect(lab.l, content="100")
  if lab.a > 1.0e-12 || lab.a < -1.0e-12 {
    fail("D50 的 a 应当为 0，实际 \{lab.a}")
  }
  if lab.b > 1.0e-12 || lab.b < -1.0e-12 {
    fail("D50 的 b 应当为 0，实际 \{lab.b}")
  }
}

///|
/// 黑色映射到 L=0。
test "Lab: 黑点映射到 L=0" {
  let lab = xyz_to_lab(XyzNumber::{ x: 0.0, y: 0.0, z: 0.0, })
  inspect(lab.l, content="0")
}

///|
/// CIE76 色差：相同值之差为 0，已知差值可精确计算。
test "delta_e76: 基本性质" {
  let a = Lab::new(50.0, 10.0, -20.0)
  inspect(delta_e76(a, a), content="0")
  // (0,0,0) 与 (3,4,0) 的欧氏距离是 5
  let b = Lab::new(3.0, 4.0, 0.0)
  let origin = Lab::new(0.0, 0.0, 0.0)
  inspect(delta_e76(b, origin), content="5")
}

///|
/// `curv` 类型的 gamma 形式（表项数为 1）。
///
/// 构造一个 256 项的合成 profile 不必要，这里直接测 `ToneCurve` 的求值语义。
test "ToneCurve: gamma 形式" {
  let c = ToneCurve::Gamma(2.0)
  inspect(c.evaluate(0.0), content="0")
  inspect(c.evaluate(1.0), content="1")
  inspect(c.evaluate(0.5), content="0.25")
}

///|
/// `ToneCurve` 的恒等语义（gamma = 1）。
test "ToneCurve: gamma=1 为恒等" {
  let c = ToneCurve::Gamma(1.0)
  inspect(c.evaluate(0.3), content="0.3")
  inspect(c.evaluate(0.8), content="0.8")
}

///|
/// `ToneCurve` 查表求值：端点必须精确。
test "ToneCurve: 查表端点" {
  let c = ToneCurve::Table([0.0, 0.5, 1.0])
  inspect(c.evaluate(0.0), content="0")
  inspect(c.evaluate(1.0), content="1")
  // 中点恰好落在中间表项
  inspect(c.evaluate(0.5), content="0.5")
}

///|
/// 输入越界时曲线求值必须被夹到 [0,1]，不得外推。
test "ToneCurve: 越界输入被夹紧" {
  let c = ToneCurve::Gamma(2.2)
  inspect(c.evaluate(-1.0), content="0")
  inspect(c.evaluate(2.0), content="1")
}

///|
/// LUT 型 profile（CMYK 打印机）必须**显式失败**，而不是静默给出错误颜色。
///
/// 这是设计决策：打印机 profile 用 A2B0 这类 LUT tag，没有 matrix/TRC。
/// 与其返回一个错的 XYZ，不如报错让调用方知道该 profile 不在支持范围内。
test "matrix_trc: LUT 型 profile 显式失败" {
  let data = @fs.read_file_to_bytes("testdata/cmyk_printer.icc")
  let profile = Profile::parse(data)
  try profile.matrix_trc() catch {
    BadTagData(tag~, reason~) => {
      // 缺少的必然是 rXYZ（第一个被要求的 matrix tag）
      inspect(tag, content="rXYZ")
      if reason == "" {
        fail("错误信息不应为空")
      }
    }
    e => fail("期望 BadTagData，实际: \{e}")
  } noraise {
    _ =>
      fail("LUT 型 profile 应当显式失败，而不是返回一个结果")
  }
}

///|
/// 显示器 profile 也应当是 matrix/TRC 型，变换可用。
test "matrix_trc: 真实显示器 profile 可用" {
  let data = @fs.read_file_to_bytes("testdata/display.icc")
  let profile = Profile::parse(data)
  let t = profile.matrix_trc()
  let white = t.to_pcs(1.0, 1.0, 1.0)
  let de = delta_e76(xyz_to_lab(white), xyz_to_lab(d50_white))
  if de > 1.0 {
    fail("显示器 profile 的白点与 D50 色差 \{de} 过大")
  }
}
