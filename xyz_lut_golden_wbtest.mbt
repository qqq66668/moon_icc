///|
/// 合成 XYZ-PCS profile（`testdata/xyz_lut.icc`）的测试金标。
///
/// **本文件由 `tools/gen_xyz_golden.py` 自动生成，请勿手工编辑。**
///
/// 参考实现：lcms2（经 Pillow 的 `ImageCms`）。该 profile 由
/// `tools/gen_xyz_lut_profile.py` 合成：PCS 为 `XYZ `，`A2B0`/`B2A0`
/// 都是恒等曲线 + 2×2×2 线性 CLUT，节点值分别取 `(i,j,k)×32768`
/// 与 `(i,j,k)×65535`。因此解析期望值是精确的：
/// 设备→XYZ 为恒等、XYZ→设备为 `XYZ/1.99997…`。
///
/// 结构体复用 `v4lut_golden_wbtest.mbt` 中的 `V4A2BCase` / `V4B2ACase`。

///|
/// 设备 → PCS 金标：设备 RGB（0..255）+ 期望的 8 位 Lab。
pub let xyz_a2b_golden : Array[V4A2BCase] = [
  { r: 0, g: 0, b: 0, lp: 0, ap: 128, bp: 128, },
  { r: 255, g: 255, b: 255, lp: 255, ap: 128, bp: 128, },
  { r: 128, g: 128, b: 128, lp: 194, ap: 128, bp: 128, },
  { r: 64, g: 64, b: 64, lp: 146, ap: 128, bp: 128, },
  { r: 192, g: 192, b: 192, lp: 228, ap: 128, bp: 128, },
  { r: 1, g: 1, b: 1, lp: 9, ap: 128, bp: 128, },
  { r: 254, g: 254, b: 254, lp: 255, ap: 128, bp: 128, },
  { r: 255, g: 0, b: 0, lp: 0, ap: 255, bp: 128, },
  { r: 0, g: 255, b: 0, lp: 255, ap: 0, bp: 255, },
  { r: 0, g: 0, b: 255, lp: 0, ap: 128, bp: 0, },
  { r: 64, g: 192, b: 32, lp: 228, ap: 0, bp: 210, },
  { r: 17, g: 34, b: 51, lp: 110, ap: 75, bp: 113, },
  { r: 200, g: 100, b: 50, lp: 176, ap: 223, bp: 158, },
  { r: 10, g: 200, b: 50, lp: 232, ap: 0, bp: 196, },
  { r: 14, g: 47, b: 60, lp: 128, ap: 33, bp: 118, },
  { r: 197, g: 26, b: 75, lp: 97, ap: 255, bp: 88, },
  { r: 40, g: 65, b: 230, lp: 147, ap: 81, bp: 62, },
  { r: 39, g: 212, b: 125, lp: 237, ap: 0, bp: 158, },
  { r: 114, g: 195, b: 64, lp: 230, ap: 53, bp: 185, },
  { r: 121, g: 190, b: 31, lp: 227, ap: 65, bp: 210, },
  { r: 108, g: 53, b: 202, lp: 134, ap: 207, bp: 61, },
  { r: 59, g: 88, b: 177, lp: 167, ap: 84, bp: 91, },
  { r: 150, g: 23, b: 4, lp: 92, ap: 255, bp: 168, },
  { r: 237, g: 34, b: 179, lp: 110, ap: 255, bp: 52, },
  { r: 112, g: 233, b: 110, lp: 246, ap: 23, bp: 171, },
  { r: 15, g: 156, b: 165, lp: 210, ap: 0, bp: 125, },
]

///|
/// 端到端金标：设备 RGB 经 PCS 再回到设备 RGB（8 位）。
pub let xyz_rgb2rgb_golden : Array[V4B2ACase] = [
  { r: 0, g: 0, b: 0, out_r: 0, out_g: 0, out_b: 0, },
  { r: 255, g: 255, b: 255, out_r: 123, out_g: 128, out_b: 105, },
  { r: 128, g: 128, b: 128, out_r: 62, out_g: 64, out_b: 53, },
  { r: 64, g: 64, b: 64, out_r: 31, out_g: 32, out_b: 26, },
  { r: 192, g: 192, b: 192, out_r: 93, out_g: 96, out_b: 79, },
  { r: 1, g: 1, b: 1, out_r: 0, out_g: 1, out_b: 0, },
  { r: 254, g: 254, b: 254, out_r: 122, out_g: 127, out_b: 105, },
  { r: 255, g: 0, b: 0, out_r: 123, out_g: 0, out_b: 0, },
  { r: 0, g: 255, b: 0, out_r: 0, out_g: 128, out_b: 0, },
  { r: 0, g: 0, b: 255, out_r: 0, out_g: 0, out_b: 105, },
  { r: 64, g: 192, b: 32, out_r: 31, out_g: 96, out_b: 13, },
  { r: 17, g: 34, b: 51, out_r: 8, out_g: 17, out_b: 21, },
  { r: 200, g: 100, b: 50, out_r: 96, out_g: 50, out_b: 21, },
  { r: 10, g: 200, b: 50, out_r: 5, out_g: 100, out_b: 21, },
  { r: 14, g: 47, b: 60, out_r: 7, out_g: 24, out_b: 25, },
  { r: 197, g: 26, b: 75, out_r: 95, out_g: 13, out_b: 31, },
  { r: 40, g: 65, b: 230, out_r: 19, out_g: 33, out_b: 95, },
  { r: 39, g: 212, b: 125, out_r: 19, out_g: 106, out_b: 52, },
  { r: 114, g: 195, b: 64, out_r: 55, out_g: 98, out_b: 26, },
  { r: 121, g: 190, b: 31, out_r: 58, out_g: 95, out_b: 13, },
  { r: 108, g: 53, b: 202, out_r: 52, out_g: 27, out_b: 83, },
  { r: 59, g: 88, b: 177, out_r: 28, out_g: 44, out_b: 73, },
  { r: 150, g: 23, b: 4, out_r: 72, out_g: 12, out_b: 2, },
  { r: 237, g: 34, b: 179, out_r: 114, out_g: 17, out_b: 74, },
  { r: 112, g: 233, b: 110, out_r: 54, out_g: 117, out_b: 45, },
  { r: 15, g: 156, b: 165, out_r: 7, out_g: 78, out_b: 68, },
]
