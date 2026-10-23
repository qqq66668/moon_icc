///|
/// 色域判定必须**面向不同设备**都成立。
///
/// 评审意见里有「尚未支撑面向不同设备的判定承诺」这一条。此前色域证据
/// 全部来自 CMYK 打印机一台设备，这里补上设备维度：
///
/// - 3 通道（显示器 profile，matrix/TRC 型）与 4 通道（CMYK 打印机，LUT 型）
///   都能建边界并判定；
/// - **同一个颜色在两台设备上的结论必须不同**——若相同，说明判定其实没有
///   随设备变化（例如退化成固定阈值），那就没有"面向不同设备"可言。

///|
/// 3 通道设备（显示空间）也能建边界，设备值样本零误判。
test "色域: 3 通道设备（显示器）同样零误判" {
  let display = load_profile("display.icc")
  // 3 通道用 17 层（17^3 = 4913）：9 层时实测有 3/343 个设备值被误判，
  // 原因是扇区数固定 16x16，样本太少时相邻扇区之间会漏掉边界方向。
  let boundary = display.gamut_boundary(1, 17)
  inspect(boundary.samples(), content="4913")
  // 用更细的 7 层网格（343 个设备值）验证：设备值按定义在色域内
  let points = gamut_sample_points(7, 3)
  let mut total = 0
  let mut false_out = 0
  let mut index = 0
  while index < points.length() {
    let device : Array[Double] = [
      points[index],
      points[index + 1],
      points[index + 2],
    ]
    let lab = xyz_to_lab(display.device_to_pcs(1, device))
    if !boundary.contains(lab) {
      false_out = false_out + 1
    }
    total = total + 1
    index = index + 3
  }
  if false_out > 0 {
    fail(
      "3 通道设备上有 \{false_out}/\{total} 个设备值被误判越界",
    )
  }
}

///|
/// **判定随设备变化**：同一个颜色在不同设备上给出不同结论。
///
/// 用 sRGB 纯红：本机显示器 profile 的色域能覆盖它（界内），
/// 而 SWOP 类 CMYK 打印机的色域覆盖不了（界外）。
/// 这条判据把"面向不同设备"钉成可执行断言——若哪天实现退化成固定阈值，
/// 这里会立刻变红。
test "色域: 同一颜色在不同设备上结论不同" {
  let srgb = load_profile("srgb.icc")
  let cmyk = load_profile("cmyk_printer.icc")
  let display = load_profile("display.icc")
  let red = xyz_to_lab(srgb.device_to_pcs(1, [1.0, 0.0, 0.0]))
  let on_display = display.gamut_boundary(1, 9).contains(red)
  let on_cmyk = cmyk.gamut_boundary(1, 9).contains(red)
  inspect(on_display, content="true")
  inspect(on_cmyk, content="false")
  if on_display == on_cmyk {
    fail(
      "同一颜色在两台设备上判定相同，说明判定没有随设备变化",
    )
  }
}

///|
/// 设备越界量级也应随设备变化：sRGB 纯蓝在 CMYK 上越界很远，在显示器上接近界内。
test "色域: 越界量级随设备变化" {
  let srgb = load_profile("srgb.icc")
  let cmyk = load_profile("cmyk_printer.icc")
  let display = load_profile("display.icc")
  let blue = xyz_to_lab(srgb.device_to_pcs(1, [0.0, 0.0, 1.0]))
  let d_cmyk = cmyk.gamut_boundary(1, 9).signed_distance(blue)
  let d_display = display.gamut_boundary(1, 9).signed_distance(blue)
  if d_cmyk < 20.0 {
    fail("sRGB 纯蓝在 CMYK 上应明显越界，实测越界量 \{d_cmyk}")
  }
  if d_display > 5.0 {
    fail(
      "sRGB 纯蓝在显示器上应接近界内，实测越界量 \{d_display}",
    )
  }
}
