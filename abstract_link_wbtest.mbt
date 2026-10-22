///|
/// 抽象 profile（`abst`）与 device link profile（`link`）的判据。
///
/// 这两类此前在覆盖矩阵里标为「部分」——入口实现了，但没有样本。
/// 现在用**合成样本 + 解析式判据**把它们钉住：
///
/// - `abstract.icc`：**恒等** PCS→PCS 映射 → 变换后 PCS 必须不变；
/// - `devicelink.icc`：`C=1-R, M=1-G, Y=1-B, K=0` 的闭式映射 → 输出必须等于该式。
///
/// 两者都由 `tools/gen_abst_link_profiles.py` 生成，且 lcms2 能读入
/// （生成脚本会当场复核）。

///|
/// 恒等抽象 profile 不得改变 PCS。
///
/// 测点在 Lab 域内取：中性轴两端、两端的明度、以及两个高彩度点。
/// 判据容差 1.0 ΔE76——2×2×2 的 CLUT 加上恒等曲线，恒等映射应当**精确**成立，
/// 容差只用来吸收 v4 Lab 编码往返的量化误差。
test "abst: 恒等抽象 profile 不改变 PCS" {
  let abst = load_profile("abstract.icc")
  inspect(abst.is_abstract(), content="true")
  inspect(abst.header.device_class, content="abst")
  let probes : Array[(Double, Double, Double)] = [
    (50.0, 0.0, 0.0),
    (100.0, 0.0, 0.0),
    (10.0, 0.0, 0.0),
    (20.0, 30.0, -40.0),
    (70.0, -20.0, 50.0),
  ]
  for p in probes {
    let want = Lab::new(p.0, p.1, p.2)
    let got = xyz_to_lab(abst.apply_abstract(1, lab_to_xyz(want)))
    let de = delta_e76(want, got)
    if de > 1.0 {
      fail(
        "恒等抽象 profile 改变了 PCS: Lab(\{p.0},\{p.1},\{p.2}) → ΔE=\{de}",
      )
    }
  }
}

///|
/// device link 必须等于闭式 `C=1-R, M=1-G, Y=1-B, K=0`。
///
/// 该映射对每个输入分量都是线性的，2 点 CLUT 的线性插值应当精确复现它；
/// 容差 0.02（≈5/255）用来吸收编码往返误差。
test "link: device link 符合解析式 C=1-R, M=1-G, Y=1-B, K=0" {
  let link = load_profile("devicelink.icc")
  inspect(link.is_device_link(), content="true")
  inspect(link.header.device_class, content="link")
  // 该 profile 的 A2B 应是 3 进 4 出
  inspect(link.a2b(1).input_channels(), content="3")
  inspect(link.a2b(1).output_channels(), content="4")
  let probes : Array[(Double, Double, Double)] = [
    (0.0, 0.0, 0.0),
    (1.0, 1.0, 1.0),
    (1.0, 0.0, 0.0),
    (0.0, 1.0, 0.0),
    (0.0, 0.0, 1.0),
    (0.5, 0.25, 0.75),
  ]
  for p in probes {
    let out = link.apply_device_link(1, [p.0, p.1, p.2])
    if out.length() != 4 {
      fail("device link 应输出 4 通道，实际 \{out.length()}")
    }
    let want : Array[Double] = [1.0 - p.0, 1.0 - p.1, 1.0 - p.2, 0.0]
    for k = 0; k < 4; k = k + 1 {
      if (out[k] - want[k]).abs() > 0.02 {
        fail(
          "RGB(\{p.0},\{p.1},\{p.2}) 的第 \{k} 通道: 期望 \{want[k]}，实际 \{out[k]}",
        )
      }
    }
  }
}

///|
/// 两类样本都必须通过必需 tag 检查（`desc` + `cprt` + `A2B0`）。
test "abst/link: 合成样本满足必需 tag" {
  for name in ["abstract.icc", "devicelink.icc"] {
    let report = load_profile(name).conformance()
    if !report.ok() {
      let mut names = ""
      for m in report.missing() {
        names = names + " " + m
      }
      fail("\{name} 缺少必需 tag:\{names}")
    }
    if !report.transform_supported() {
      fail("\{name} 应报告为支持变换")
    }
  }
}
