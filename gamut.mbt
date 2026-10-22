///|
/// 色域边界描述符（Gamut Boundary Descriptor）。
///
/// ## 为什么不能再用「往返 ΔE」
///
/// 上一版把「PCS → 设备 → PCS 的往返误差」当色域判据，并用中性轴基线
/// 自适应阈值。这个判据混进了**颜色映射误差**：同一个 profile 的 A2B 与
/// B2A 是两张独立的表，CMYK 还受 GCR 与总墨量限制，二者并不严格互逆。
///
/// 实测（1296 个 CMYK 设备值网格样本，按定义**全部在色域内**）：
/// 往返误差平均 6.78 ΔE、最大 19.73，用当时的容差 5.59 判定会把
/// **696/1296 = 53.7%** 的色域内颜色误判成越界。
///
/// ## 本实现的判据
///
/// 只用**设备值产生的颜色**建立边界：以 `Lab(L*=50, a*=0, b*=0)` 为中心，
/// 把方向切成扇区，每个扇区记录样本中的最大半径 r_max（球面直方图）。
/// 判定一个颜色是否在色域内，就是看它的半径是否不超过所在扇区的 r_max。
///
/// 这条判据**与映射误差完全无关**：边界点全部来自设备本身，
/// A2B/B2A 是否互逆不影响结果。扇区离散化带来的误差用相邻扇区插值削弱。
pub struct GamutBoundary {
  /// 每轴的扇区数（alpha 分 0..360、theta 分 0..180）。
  sectors : Int32
  /// 每个扇区的最大半径；0 且 `filled` 为 false 表示该扇区无样本。
  radii : Array[Double]
  /// 该扇区是否采到过样本。
  filled : Array[Bool]
  /// 建边界时用的样本数。
  samples : Int32
  /// 采样网格每轴的层数。
  steps : Int32
}

///|
/// Lab → 以 (L*=50, a*=0, b*=0) 为原点的球面坐标（r, alpha 度, theta 度）。
///
/// 与 lcms2 的 `ToSpherical`（`src/cmssm.c:119`）取同一约定，
/// 便于用它的色域边界描述符做对拍；实现是本项目自己写的。
fn lab_to_spherical(lab : Lab) -> (Double, Double, Double) {
  let l = lab.l - 50.0
  let a = lab.a
  let b = lab.b
  let r = @math.pow(l * l + a * a + b * b, 0.5)
  if r == 0.0 {
    return (0.0, 0.0, 0.0)
  }
  let pi = 3.141592653589793
  // alpha: 在 a-b 平面内的角度（0..360），从 b 轴起算
  let mut alpha = @math.atan2(a, b) * 180.0 / pi
  if alpha < 0.0 {
    alpha = alpha + 360.0
  }
  // theta: 与 L 轴的夹角（0..180）
  let theta = @math.atan2(@math.pow(a * a + b * b, 0.5), l) * 180.0 / pi
  (r, alpha, theta)
}

///|
/// 球面方向 → 扇区线性下标。
fn sector_of(alpha : Double, theta : Double, sectors : Int32) -> Int32 {
  let s = sectors.to_double()
  let mut ai = (alpha * s / 360.0).to_int()
  let mut ti = (theta * s / 180.0).to_int()
  if ai >= sectors {
    ai = sectors - 1
  }
  if ti >= sectors {
    ti = sectors - 1
  }
  if ai < 0 {
    ai = 0
  }
  if ti < 0 {
    ti = 0
  }
  ti * sectors + ai
}

///|
/// 把设备空间的采样网格映射成 PCS Lab 点，建出色域边界。
///
/// `steps` 是每轴的层数：CMYK 4 通道时 `steps=6` 得到 1296 个样本，
/// `steps=9` 得到 6561 个。矩阵/TRC 型 profile 按 3 通道处理。
///
/// 采样值取 `i/(steps-1)`，覆盖 0..1 全量程。
pub fn Profile::gamut_boundary(
  self : Profile,
  intent : Int32,
  steps : Int32,
) -> GamutBoundary raise IccError {
  if steps < 2 {
    raise BadTagData(
      tag="gamut",
      reason="色域边界的采样层数至少为 2，实际 \{steps}",
    )
  }
  let channels = self.device_channels(intent)
  if channels != 3 && channels != 4 {
    raise BadTagData(
      tag="gamut",
      reason="色域边界只支持 3 或 4 通道设备空间，实际 \{channels}",
    )
  }
  let sectors = 16
  let total = sectors * sectors
  let radii : Array[Double] = []
  let filled : Array[Bool] = []
  let mut init = 0
  while init < total {
    radii.push(0.0)
    filled.push(false)
    init = init + 1
  }
  let mut samples = 0
  let grid = gamut_sample_points(steps, channels)
  let mut index = 0
  while index < grid.length() {
    let device : Array[Double] = if channels == 3 {
      [grid[index], grid[index + 1], grid[index + 2]]
    } else {
      [grid[index], grid[index + 1], grid[index + 2], grid[index + 3]]
    }
    let lab = xyz_to_lab(self.device_to_pcs(intent, device))
    let (r, alpha, theta) = lab_to_spherical(lab)
    let sector = sector_of(alpha, theta, sectors)
    if !filled[sector] || r > radii[sector] {
      radii[sector] = r
      filled[sector] = true
    }
    samples = samples + 1
    index = index + channels
  }
  { sectors, radii, filled, samples, steps, }
}

///|
/// 设备通道数：LUT 型看 A2B 表，matrix/TRC 型按 3 通道。
fn Profile::device_channels(
  self : Profile,
  intent : Int32,
) -> Int32 raise IccError {
  if self.has_lut() {
    self.a2b(intent).input_channels()
  } else if self.has_matrix_trc() {
    3
  } else {
    raise BadTagData(
      tag="A2B0",
      reason="profile 既没有 matrix/TRC tag，也没有 A2B LUT tag，无法确定设备通道数",
    )
  }
}

///|
/// 采样网格的笛卡尔展开（3/4 通道通用）。
///
/// 返回一维数组，每 `channels` 个值为一个设备值组合。
pub fn gamut_sample_points(steps : Int32, channels : Int32) -> Array[Double] {
  let levels : Array[Double] = []
  let denom = (steps - 1).to_double()
  for i = 0; i < steps; i = i + 1 {
    levels.push(i.to_double() / denom)
  }
  let out : Array[Double] = []
  if channels == 3 {
    for a in levels {
      for b in levels {
        for c in levels {
          out.push(a)
          out.push(b)
          out.push(c)
        }
      }
    }
  } else {
    for a in levels {
      for b in levels {
        for c in levels {
          for d in levels {
            out.push(a)
            out.push(b)
            out.push(c)
            out.push(d)
          }
        }
      }
    }
  }
  out
}

///|
/// 某扇区及其 3×3 邻域内的最大半径。
///
/// 为什么要取邻域最大值：扇区是方向上的离散化，若只查本扇区，细采样得到的
/// 方向可能落在两个粗采样扇区之间，半径略大于任一侧，于是**色域内的颜色
/// 被判越界**。取邻域最大值把这种离散化误差压掉（代价是边界略微外扩，
/// 属于保守方向：宁可少报越界，也不误报）。
fn GamutBoundary::neighbourhood_max(
  self : GamutBoundary,
  sector : Int32,
) -> (Double, Bool) {
  let s = self.sectors
  let ti = sector / s
  let ai = sector % s
  let mut best = 0.0
  let mut any = false
  for dt = -1; dt <= 1; dt = dt + 1 {
    for da = -1; da <= 1; da = da + 1 {
      let t = ti + dt
      if t < 0 || t >= s {
        continue
      }
      let mut a = ai + da
      if a < 0 {
        a = a + s
      }
      if a >= s {
        a = a - s
      }
      let idx = t * s + a
      if self.filled[idx] {
        any = true
        if self.radii[idx] > best {
          best = self.radii[idx]
        }
      }
    }
  }
  (best, any)
}

///|
/// 该颜色是否在色域内：半径不超过所在扇区（含 3×3 邻域）的最大半径。
///
/// 空扇区（没有采样到的方向）保守地判为**不在**色域内，
/// 并可用 `GamutBoundary::coverage` 检查采样充分性。
pub fn GamutBoundary::contains(self : GamutBoundary, lab : Lab) -> Bool {
  let (r, alpha, theta) = lab_to_spherical(lab)
  let (rmax, any) = self.neighbourhood_max(
    sector_of(alpha, theta, self.sectors),
  )
  if !any {
    return false
  }
  r <= rmax * 1.0000001
}

///|
/// 到色域边界的带符号距离（Lab 单位，即 ΔE76 量级）。
///
/// 负值表示在色域内、离边界还有多远；正值表示越界了多少。
/// 这比「in/out」二元判定更有用：可以区分「刚好在边界上」与「远在界外」。
pub fn GamutBoundary::signed_distance(
  self : GamutBoundary,
  lab : Lab,
) -> Double {
  let (r, alpha, theta) = lab_to_spherical(lab)
  let (rmax, any) = self.neighbourhood_max(
    sector_of(alpha, theta, self.sectors),
  )
  if !any {
    return r
  }
  r - rmax
}

///|
/// 采样覆盖率：采到样本的扇区占比。用来判断采样层数是否足够
/// （覆盖率过低说明边界有洞，判定会保守地偏严）。
pub fn GamutBoundary::coverage(self : GamutBoundary) -> Double {
  let mut n = 0
  for f in self.filled {
    if f {
      n = n + 1
    }
  }
  n.to_double() / self.filled.length().to_double()
}

///|
/// 建边界时使用的样本数。
pub fn GamutBoundary::samples(self : GamutBoundary) -> Int32 {
  self.samples
}

///|
/// 每轴扇区数。
pub fn GamutBoundary::sectors(self : GamutBoundary) -> Int32 {
  self.sectors
}

///|
/// 解析采样层数参数：仅接受 2..12 的十进制整数。
///
/// 上限 12 是为了让 4 通道的笛卡尔积不至于爆炸（12^4 = 20736 个样本）。
pub fn parse_steps(text : String) -> Int32? {
  if text.length() == 0 || text.length() > 2 {
    return None
  }
  let mut value = 0
  for i = 0; i < text.length(); i = i + 1 {
    let c = text[i]
    if c < '0' || c > '9' {
      return None
    }
    value = value * 10 + (c.to_int() - '0'.to_int())
  }
  if value < 2 || value > 12 {
    None
  } else {
    Some(value)
  }
}
