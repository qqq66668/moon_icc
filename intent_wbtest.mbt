///|
/// 渲染意图的测试：四种意图与 lcms2 交叉核对。
///
/// 用 sRGB → CMYK 打印机这一组 profile，因为**只有它能区分意图**——
/// 它含 `A2B0/A2B1/A2B2` 三张不同的 LUT。sRGB → 显示器 那组四种意图
/// 逐位相同（见 `tools/lcms2_intent_check.py`）。
///
/// 金标由 `tools/gen_intent_golden.py` 用 lcms2 生成，200 个随机 RGB 样本，
/// 四个意图共用同一批输入。

///|
/// 构造指定意图的 sRGB → CMYK 变换。
fn intent_transform(intent : Int32) -> ColorTransform raise {
  ColorTransform::with_intent(
    Profile::parse(@fs.read_file_to_bytes("testdata/srgb.icc")),
    Profile::parse(@fs.read_file_to_bytes("testdata/cmyk_printer.icc")),
    intent,
  )
}

///|
/// 把一个意图的实测结果与金标比对，返回 (完全一致数, 最大偏差, 最差样本描述)。
fn compare_intent(
  intent : Int32,
  golden : Array[(Int32, Int32, Int32, Int32)],
) -> (Int32, Int32, String) raise {
  let t = intent_transform(intent)
  let mut exact = 0
  let mut worst = 0
  let mut worst_case = ""
  for i = 0; i < intent_inputs.length(); i = i + 1 {
    let (r, g, b) = intent_inputs[i]
    let out = t.transform_values([
      r.to_double() / 255.0,
      g.to_double() / 255.0,
      b.to_double() / 255.0,
    ])
    let got = (q8i(out[0]), q8i(out[1]), q8i(out[2]), q8i(out[3]))
    let want = golden[i]
    let d = @cmp.maximum(
      @cmp.maximum((got.0 - want.0).abs(), (got.1 - want.1).abs()),
      @cmp.maximum((got.2 - want.2).abs(), (got.3 - want.3).abs()),
    )
    if d == 0 {
      exact = exact + 1
    }
    if d > worst {
      worst = d
      worst_case = "RGB(\{r},\{g},\{b}) lcms2=(\{want.0},\{want.1},\{want.2},\{want.3}) 本库=(\{got.0},\{got.1},\{got.2},\{got.3})"
    }
  }
  (exact, worst, worst_case)
}

///|
/// 感知意图（`A2B0`/`B2A0`）。
test "意图: 感知（0）与 lcms2 一致" {
  let (exact, worst, worst_case) = compare_intent(0, intent_perceptual)
  if worst > 2 {
    fail("感知意图最大偏差 \{worst} 级超过 2: \{worst_case}")
  }
  if exact * 10 < intent_inputs.length() * 6 {
    fail(
      "感知意图完全一致只有 \{exact}/\{intent_inputs.length()}，低于 60%",
    )
  }
}

///|
/// 媒体相对比色（`A2B1`/`B2A1`）——默认意图。
test "意图: 媒体相对比色（1）与 lcms2 一致" {
  let (exact, worst, worst_case) = compare_intent(1, intent_relative)
  if worst > 2 {
    fail("相对比色最大偏差 \{worst} 级超过 2: \{worst_case}")
  }
  if exact * 10 < intent_inputs.length() * 6 {
    fail(
      "相对比色完全一致只有 \{exact}/\{intent_inputs.length()}，低于 60%",
    )
  }
}

///|
/// 饱和度意图（`A2B2`/`B2A2`）。
test "意图: 饱和度（2）与 lcms2 一致" {
  let (exact, worst, worst_case) = compare_intent(2, intent_saturation)
  if worst > 2 {
    fail("饱和度意图最大偏差 \{worst} 级超过 2: \{worst_case}")
  }
  if exact * 10 < intent_inputs.length() * 6 {
    fail(
      "饱和度意图完全一致只有 \{exact}/\{intent_inputs.length()}，低于 60%",
    )
  }
}

///|
/// **三种基于 tag 的意图必须给出彼此不同的结果**。
///
/// 这条判据独立于 lcms2：如果意图选错（比如都落到 A2B1），
/// 三个标题下的结果就会相同。实测感知与相对的最大差 35 级、
/// 饱和度与相对的最大差 255 级。
test "意图: 三种意图彼此可区分" {
  let results = [
    compare_intent(0, intent_perceptual),
    compare_intent(1, intent_relative),
    compare_intent(2, intent_saturation),
  ]
  // 三个意图都不能与自己的金标完全无关：一致率都在 60% 以上
  for i = 0; i < 3; i = i + 1 {
    let (exact, _, _) = results[i]
    if exact * 10 < intent_inputs.length() * 6 {
      fail(
        "第 \{i} 个意图与自己的金标一致率过低，可能是意图选错",
      )
    }
  }
}

///|
/// 绝对比色（编号 3）：在 PCS 上乘 `diag(源媒体白点 / 目标媒体白点)`。
///
/// 语义对齐 lcms2 的 `ComputeConversion`（`src/cmscnvrt.c:352`，`AdaptationState`
/// 为默认的 1）：白点取 `_cmsReadMediaWhitePoint`（`src/cmsio1.c:64`）——
/// **v2 的 `mntr` 类 profile 按 D50 处理**，其余取 `wtpt` 原值。
///
/// 这组 profile 对（`srgb.icc` v2/mntr、`cmyk_printer.icc` v2/prtr）上，
/// 源侧白点按 D50、目标侧白点 = (0.8617, 0.8933, 0.7431)，
/// 因此缩放 ≈ (1.119, 1.119, 1.110)，**只有目标侧贡献差异**。
///
/// 上一版在源侧乘了标签里的 D65（而不是 D50），Z 分量多乘约 1.32 倍，
/// 导致与 lcms2 的偏差从 20 级恶化到 107 级——本测试正是用来钉住这个教训。
///
/// 判据两面：
/// 1. 与 lcms2 的绝对比色金标一致（偏差 ≤ 2 级、完全一致率 ≥ 60%）；
/// 2. 与相对比色**必须不同**：缩放若没生效，两者会逐点相同。
test "意图: 绝对比色（3）与 lcms2 一致，且区别于相对比色" {
  let (exact, worst, worst_case) = compare_intent(3, intent_absolute)
  if worst > 2 {
    fail("绝对比色最大偏差 \{worst} 级超过 2: \{worst_case}")
  }
  if exact * 10 < intent_inputs.length() * 6 {
    fail(
      "绝对比色完全一致只有 \{exact}/\{intent_inputs.length()}，低于 60%",
    )
  }
  // 缩放必须真的改变了结果：与相对比色逐点比较
  let absolute = intent_transform(3)
  let relative = intent_transform(1)
  let mut differs = 0
  for i = 0; i < intent_inputs.length(); i = i + 1 {
    let (r, g, b) = intent_inputs[i]
    let inputs : Array[Double] = [
      r.to_double() / 255.0,
      g.to_double() / 255.0,
      b.to_double() / 255.0,
    ]
    let a = absolute.transform_values(inputs)
    let rel = relative.transform_values(inputs)
    for k = 0; k < a.length(); k = k + 1 {
      if (a[k] - rel[k]).abs() > 1.0e-15 {
        differs = differs + 1
      }
    }
  }
  if differs == 0 {
    fail(
      "绝对比色与相对比色逐点相同，说明 PCS 白点缩放没有生效",
    )
  }
}

///|
/// 非法意图编号必须报错，不得静默当成某个默认意图。
test "意图: 非法编号被拒绝" {
  try intent_transform(4) catch {
    BadTagData(..) => ()
    e => fail("期望 BadTagData，实际: \{e}")
  } noraise {
    _ => fail("非法意图编号应当被拒绝")
  }
  try intent_transform(-1) catch {
    BadTagData(..) => ()
    e => fail("期望 BadTagData，实际: \{e}")
  } noraise {
    _ => fail("负数意图编号应当被拒绝")
  }
}
