///|
/// 软打样链与色域判断的测试。
///
/// 这两项能力是「完整处理链」的要求点：评审明确指出本库只做了中间一段。
/// 判据分两类：
/// - **自洽性**：打样 profile 与显示 profile 相同时，链路应退化为直接变换；
/// - **物理正确性**：经过 CMYK 打样后，超出印刷色域的颜色必须被改变；
///   色域判断必须把中性灰判为 in、把纯黑与 sRGB 原色判为 out。

///|
fn load_profile(name : String) -> Profile raise {
  Profile::parse(@fs.read_file_to_bytes("testdata/\{name}"))
}

///|
/// 8 位量化后的分量差最大值。
fn max_level_diff(a : Array[Double], b : Array[Double]) -> Int32 {
  let mut worst = 0
  for k = 0; k < a.length() && k < b.length(); k = k + 1 {
    let d = (a[k] - b[k]).abs() * 255.0
    let di = d.to_int()
    let level = if d - di.to_double() >= 0.5 { di + 1 } else { di }
    if level > worst {
      worst = level
    }
  }
  worst
}

///|
/// 打样链在「打样 profile = 显示 profile」时必须退化为直接变换。
///
/// 这是链路本身的自洽性判据：中间那次往返若写错（例如把 A2B/B2A 用反、
/// 或漏掉一次阶段），这里会立刻暴露。
test "打样: 打样 profile 与显示相同时退化为直接变换" {
  let chain = ColorTransform::proofing(
    load_profile("srgb.icc"),
    load_profile("display.icc"),
    load_profile("display.icc"),
    1,
    1,
  )
  let direct = ColorTransform::with_intent(
    load_profile("srgb.icc"),
    load_profile("display.icc"),
    1,
  )
  for i = 0; i <= 255; i = i + 17 {
    let v = i.to_double() / 255.0
    let (proof_values, shown) = chain.evaluate([v, v, v])
    // 打样设备与显示设备是同一个，两列应当一致
    if max_level_diff(proof_values, shown) > 1 {
      fail(
        "打样值与显示值在输入 \{i} 上相差 \{max_level_diff(proof_values, shown)} 级",
      )
    }
    // 也与直接变换一致
    let want = direct.transform_values([v, v, v])
    if max_level_diff(shown, want) > 1 {
      fail(
        "打样链路与直接变换在输入 \{i} 上相差 \{max_level_diff(shown, want)} 级",
      )
    }
  }
}

///|
/// 经过 CMYK 打样后，超出印刷色域的颜色**必须**被改变。
///
/// 用 sRGB 的纯绿：SWOP 类 CMYK 覆盖不了它，打样链会把它压回色域内。
/// 判据取 8 级以上差异——这同时排除了量化噪声。
test "打样: 超色域颜色经 CMYK 打样后被显著改变" {
  let chain = ColorTransform::proofing(
    load_profile("srgb.icc"),
    load_profile("cmyk_printer.icc"),
    load_profile("display.icc"),
    1,
    1,
  )
  let direct = ColorTransform::with_intent(
    load_profile("srgb.icc"),
    load_profile("display.icc"),
    1,
  )
  let (proof_values, shown) = chain.evaluate([0.0, 1.0, 0.0])
  if proof_values.length() != 4 {
    fail(
      "打样设备应为 4 通道（CMYK），实际 \{proof_values.length()}",
    )
  }
  let want = direct.transform_values([0.0, 1.0, 0.0])
  let diff = max_level_diff(shown, want)
  if diff <= 8 {
    fail(
      "纯绿经 CMYK 打样后只差 \{diff} 级，打样链可能没有真正经过打样设备",
    )
  }
}

///|
/// 打样链的意图语义：打样意图取绝对比色时，结果必须区别于相对比色。
test "打样: 打样意图为绝对比色时结果不同" {
  let relative = ColorTransform::proofing(
    load_profile("srgb.icc"),
    load_profile("cmyk_printer.icc"),
    load_profile("display.icc"),
    1,
    1,
  )
  let absolute = ColorTransform::proofing(
    load_profile("srgb.icc"),
    load_profile("cmyk_printer.icc"),
    load_profile("display.icc"),
    1,
    3,
  )
  let mut differs = 0
  for i = 0; i <= 255; i = i + 17 {
    let v = i.to_double() / 255.0
    let (_, a) = absolute.evaluate([v, v, v])
    let (_, r) = relative.evaluate([v, v, v])
    if max_level_diff(a, r) > 1 {
      differs = differs + 1
    }
  }
  if differs == 0 {
    fail(
      "打样意图取绝对比色与相对比色完全一致，白点缩放没有生效",
    )
  }
}

///|
/// 与 lcms2 的 `cmsCreateProofingTransform` 对拍。
///
/// 金标由 `tools/gen_proof_golden.py` 生成：用 MSYS2 gcc 编译 `_research` 下
/// 的 Little-CMS 源码，再调用 `cmsCreateProofingTransform`
/// （`SOFTPROOFING | NOOPTIMIZE`）。这是打样链的**外部判据**——
/// 链路里任何一步写反都会让偏差从 1 级跳到几十级。
///
/// 实测（2026-10-20）：相对/相对 7/16 完全一致、最大 1 级；
/// 相对/绝对打样 9/16 完全一致、最大 1 级。1 级的残余差来自打样链
/// 比单次变换多经过两次 LUT 求值（lcms2 内部用浮点、本库在 LUT 边界量化），
/// 因此完全一致率门槛设为 40%，硬判据仍是「最大偏差 ≤ 2 级」。
test "打样: 与 lcms2 proofing 变换对拍" {
  let compare = fn(
    golden : Array[(Int32, Int32, Int32, Int32)],
    proof_intent : Int32,
  ) -> (Int32, Int32, String) raise {
    let chain = ColorTransform::proofing(
      load_profile("srgb.icc"),
      load_profile("cmyk_printer.icc"),
      load_profile("display.icc"),
      1,
      proof_intent,
    )
    let mut exact = 0
    let mut worst = 0
    let mut worst_case = ""
    for row in golden {
      let (index, wr, wg, wb) = row
      let v = index.to_double() / 255.0
      let (_, shown) = chain.evaluate([v, v, v])
      let got = (q8i(shown[0]), q8i(shown[1]), q8i(shown[2]))
      let d = @cmp.maximum(
        @cmp.maximum((got.0 - wr).abs(), (got.1 - wg).abs()),
        (got.2 - wb).abs(),
      )
      if d == 0 {
        exact = exact + 1
      }
      if d > worst {
        worst = d
        worst_case = "输入 \{index}: lcms2=(\{wr},\{wg},\{wb}) 本库=(\{got.0},\{got.1},\{got.2})"
      }
    }
    (exact, worst, worst_case)
  }
  let (exact, worst, worst_case) = compare(proof_golden_1_1, 1)
  if worst > 2 {
    fail(
      "打样（相对/相对）最大偏差 \{worst} 级超过 2: \{worst_case}",
    )
  }
  if exact * 10 < proof_golden_1_1.length() * 4 {
    fail(
      "打样（相对/相对）完全一致只有 \{exact}/\{proof_golden_1_1.length()}，低于 40%",
    )
  }
  let (exact_a, worst_a, worst_case_a) = compare(proof_golden_1_3, 3)
  if worst_a > 2 {
    fail(
      "打样（打样意图=绝对比色）最大偏差 \{worst_a} 级超过 2: \{worst_case_a}",
    )
  }
  if exact_a * 10 < proof_golden_1_3.length() * 4 {
    fail(
      "打样（打样意图=绝对比色）完全一致只有 \{exact_a}/\{proof_golden_1_3.length()}，低于 40%",
    )
  }
}

///|
/// 色域判断的基线：中性轴往返误差应落在可解释的范围内。
///
/// 本机 Agfa SWOP CMYK profile 受 GCR 与总墨量限制，中性灰往返本就有
/// 几个 ΔE 的底噪；这个测试把它的量级钉住，防止判据漂移。
test "色域: 中性轴基线在合理范围" {
  let target = load_profile("cmyk_printer.icc")
  let baseline = target.neutral_round_trip_baseline(1)
  if baseline < 2.0 || baseline > 8.0 {
    fail("中性轴基线 \{baseline} 超出预期范围 2..8")
  }
  let tol = target.gamut_tolerance(1)
  if tol < 2.0 || tol > 10.0 {
    fail("自适应容差 \{tol} 超出预期范围 2..10")
  }
}

///|
/// 色域判断的物理正确性：
/// - 中性灰、纸白 → 在色域内；
/// - 纯黑、sRGB 高饱和原色 → 超色域。
///
/// 纯黑判 out 不是缺陷：纸上的黑达不到 L*=0；原色判 out 也不是缺陷：
/// SWOP 类 CMYK 的色域本身覆盖不了 sRGB 的原色。
test "色域: 灰与白在色域内，黑与原色超色域" {
  let target = load_profile("cmyk_printer.icc")
  let source = load_profile("srgb.icc")
  let gray50 = lab_to_xyz(Lab::new(50.0, 0.0, 0.0))
  inspect(target.in_gamut(1, gray50), content="true")
  inspect(target.in_gamut(1, gray50), content="true")
  // 纸白：PCS 白点
  inspect(target.in_gamut(1, d50_white), content="true")
  // 纯黑：超出纸张能达到的最深黑
  let black = XyzNumber::new(0.0, 0.0, 0.0)
  inspect(target.in_gamut(1, black), content="false")
  // sRGB 纯绿与纯蓝：SWOP CMYK 覆盖不了
  let green = source.device_to_pcs(1, [0.0, 1.0, 0.0])
  let blue = source.device_to_pcs(1, [0.0, 0.0, 1.0])
  inspect(target.in_gamut(1, green), content="false")
  inspect(target.in_gamut(1, blue), content="false")
}

///|
/// 色域判断必须与往返误差一致：in ⇔ ΔE ≤ 容差。
test "色域: 判定与往返误差自洽" {
  let target = load_profile("cmyk_printer.icc")
  let source = load_profile("srgb.icc")
  let tol = target.gamut_tolerance(1)
  let samples : Array[(Double, Double, Double)] = [
    (0.0, 0.0, 0.0),
    (1.0, 1.0, 1.0),
    (0.5, 0.5, 0.5),
    (0.0, 1.0, 0.0),
    (0.8, 0.6, 0.4),
  ]
  for s in samples {
    let xyz = source.device_to_pcs(1, [s.0, s.1, s.2])
    let de = target.round_trip_delta_e(1, xyz)
    let verdict = target.in_gamut(1, xyz)
    if verdict != (de <= tol) {
      fail("色域判定与 ΔE=\{de} 容差=\{tol} 不一致")
    }
  }
}
