///|
/// 命令行工具：解析 ICC profile 并打印头部与 tag 表。
///
/// 用途有二：
/// 1. 给使用者一个可直接运行的示例；
/// 2. 作为外部 oracle 差分脚本的被测端——脚本用 Python 独立解析同一文件，
///    两边的输出逐字段比对。
///
/// 用法：
///   `moon run cmd/main -- parse <profile 路径>`
///   `moon run cmd/main -- transform <profile 路径>`
///
/// 输出为稳定的纯文本格式，便于脚本解析。

///|
/// 把 tag 表渲染为每行一个条目的文本。
fn render_tags(entries : Array[@moon_icc.IccTagEntry]) -> String {
  let buf = StringBuilder()
  for e in entries {
    buf.write("\{e.signature} \{e.offset} \{e.size}\n")
  }
  buf.to_string()
}

///|
/// 解析一个 profile 文件并打印结果。
fn describe(path : String) -> Unit raise {
  let data = @fs.read_file_to_bytes(path)
  let header = @moon_icc.parse_header(data)
  println("size \{header.size}")
  println("version \{header.major_version}.\{header.minor_version}")
  println("class \{header.device_class}")
  println("colorspace \{header.color_space}")
  println("pcs \{header.pcs}")
  println("datetime \{header.date_time.to_iso_string()}")
  println("intent \{header.rendering_intent}")
  println(
    "illuminant \{header.illuminant.x} \{header.illuminant.y} \{header.illuminant.z}",
  )
  let entries = @moon_icc.parse_tag_table(data, header)
  println("tagcount \{entries.length()}")
  println(render_tags(entries))
}

///|
/// 对给定输入值做 matrix/TRC 变换并打印结果。
///
/// 输出格式：每行 `样本序号 输入 R G B X Y Z L a b`，
/// 便于外部 oracle 脚本逐行比对。
fn transform_samples(
  profile : @moon_icc.Profile,
  samples : Array[Double],
) -> Unit raise {
  let t = profile.matrix_trc()
  for v in samples {
    let xyz = t.to_pcs(v, v, v)
    let lab = @moon_icc.xyz_to_lab(xyz)
    println("sample \{v} \{xyz.x} \{xyz.y} \{xyz.z} \{lab.l} \{lab.a} \{lab.b}")
  }
}

///|
/// 读取 profile 并对固定样本点做变换。
///
/// 样本点刻意包含中间调（0.05..0.95），只有这样才能钉住
/// TRC 与矩阵的先后顺序——黑白点在任何顺序下都正确。
fn read_and_transform(path : String) -> Unit raise {
  let data = @fs.read_file_to_bytes(path)
  let profile = @moon_icc.Profile::parse(data)
  let samples : Array[Double] = [
    0.0, 0.05, 0.1, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 0.95, 1.0,
  ]
  transform_samples(profile, samples)
}

///|
/// 端到端变换：源 profile → 目标 profile，输出 8 位量化结果。
///
/// 输出格式：每行 `link <输入> <输出通道...>`，量化到 0..255，
/// 便于与 lcms2 之类的参考实现直接比对（参考实现通常在 8 位域上给结果）。
///
/// 输出通道数由**目标 profile** 决定：显示器 profile 是 3 个（RGB），
/// 打印机 profile 是 4 个（CMYK）。因此同一命令既能看 sRGB → 显示器，
/// 也能看 sRGB → CMYK。
///
/// 驱动样本是灰阶（输入三通道相同）。对 CMYK 目标而言这不是"灰度"——
/// 因为 CMYK 有四通道，灰阶只覆盖其中一个切片，但足以对比实现差异。
///
/// `intent` 用**意图名**而不是数字，避免在此处引入整数解析：
/// `perceptual` / `relative` / `saturation` / `absolute`。
fn read_and_link(
  source_path : String,
  dest_path : String,
  intent : Int32,
) -> Unit raise {
  let src_data = @fs.read_file_to_bytes(source_path)
  let dst_data = @fs.read_file_to_bytes(dest_path)
  let transform = @moon_icc.ColorTransform::with_intent(
    @moon_icc.Profile::parse(src_data),
    @moon_icc.Profile::parse(dst_data),
    intent,
  )
  println("intent \{intent}")
  println("src_channels \{transform.source_channels()}")
  println("dst_channels \{transform.destination_channels()}")
  for i = 0; i <= 255; i = i + 1 {
    let v = i.to_double() / 255.0
    let out = transform.transform_values([v, v, v])
    let buf = StringBuilder()
    for x in out {
      buf.write(" \{quantise8(x)}")
    }
    println("link \{i}\{buf.to_string()}")
  }
}

///|
/// 软打样：源设备 → 打样设备 → 显示设备。
///
/// 每行 `proof <索引> | <打样设备值> | <显示设备值>`，均量化到 0..255。
/// 前者说明「这张图印在目标设备上要用多少墨」，后者说明「屏幕上该显示成什么」。
fn read_and_proof(
  source_path : String,
  proof_path : String,
  display_path : String,
  intent : Int32,
  proof_intent : Int32,
) -> Unit raise {
  let chain = @moon_icc.ColorTransform::proofing(
    @moon_icc.Profile::parse(@fs.read_file_to_bytes(source_path)),
    @moon_icc.Profile::parse(@fs.read_file_to_bytes(proof_path)),
    @moon_icc.Profile::parse(@fs.read_file_to_bytes(display_path)),
    intent,
    proof_intent,
  )
  println("intent \{intent}")
  println("proof_intent \{proof_intent}")
  println("proof_channels \{chain.proof_channels()}")
  println("display_channels \{chain.display_channels()}")
  for i = 0; i <= 255; i = i + 17 {
    let v = i.to_double() / 255.0
    let (proof_values, shown) = chain.evaluate([v, v, v])
    let pb = StringBuilder()
    for x in proof_values {
      pb.write(" \{quantise8(x)}")
    }
    let sb = StringBuilder()
    for x in shown {
      sb.write(" \{quantise8(x)}")
    }
    println("proof \{i} |\{pb.to_string()} |\{sb.to_string()}")
  }
}

///|
/// 色域判断：源 profile 的样本能否被目标 profile 表达。
///
/// 每行 `gamut <索引> <R> <G> <B> de=<ΔE76> <in|out>`。
/// 样本含 8 个 RGB 角点（暴露色域裁剪）与灰阶（确认中性色不误报）。
fn read_and_gamut(
  source_path : String,
  target_path : String,
  intent : Int32,
) -> Unit raise {
  let source = @moon_icc.Profile::parse(@fs.read_file_to_bytes(source_path))
  let target = @moon_icc.Profile::parse(@fs.read_file_to_bytes(target_path))
  println("intent \{intent}")
  println("tolerance \{target.gamut_tolerance(intent)}")
  let corners : Array[(Double, Double, Double)] = [
    (0.0, 0.0, 0.0),
    (1.0, 1.0, 1.0),
    (1.0, 0.0, 0.0),
    (0.0, 1.0, 0.0),
    (0.0, 0.0, 1.0),
    (0.0, 1.0, 1.0),
    (1.0, 0.0, 1.0),
    (1.0, 1.0, 0.0),
  ]
  let mut index = 0
  for c in corners {
    report_gamut(index, source, target, intent, c.0, c.1, c.2)
    index = index + 1
  }
  for i = 0; i <= 255; i = i + 17 {
    let v = i.to_double() / 255.0
    report_gamut(index, source, target, intent, v, v, v)
    index = index + 1
  }
}

///|
/// 单个样本的色域判定（供 `read_and_gamut` 调用）。
fn report_gamut(
  index : Int32,
  source : @moon_icc.Profile,
  target : @moon_icc.Profile,
  intent : Int32,
  r : Double,
  g : Double,
  b : Double,
) -> Unit raise {
  let xyz = source.device_to_pcs(intent, [r, g, b])
  let de = target.round_trip_delta_e(intent, xyz)
  let verdict = if target.in_gamut(intent, xyz) { "in" } else { "out" }
  println(
    "gamut \{index} \{quantise8(r)} \{quantise8(g)} \{quantise8(b)} de=\{de} \{verdict}",
  )
}

///|
/// 把意图名解析为编号；无法识别时返回 `None`（不静默回退）。
fn parse_intent(name : String) -> Int32? {
  match name {
    "perceptual" => Some(0)
    "relative" => Some(1)
    "saturation" => Some(2)
    "absolute" => Some(3)
    _ => None
  }
}

///|
/// 取可选位置的意图参数：缺省返回 `default`，给了但无法识别则抛错。
fn parse_optional_intent(
  args : Array[String],
  index : Int32,
  default : Int32,
) -> Int32? {
  if index >= args.length() {
    return Some(default)
  }
  parse_intent(args[index])
}

///|
/// 取可选意图并在无法识别时打印提示；返回 `None` 表示应中止。
fn required_intent(
  args : Array[String],
  index : Int32,
  default : Int32,
  what : String,
) -> Int32? {
  match parse_optional_intent(args, index, default) {
    Some(v) => Some(v)
    None => {
      println(
        "无法识别的\{what} \"\{args[index]}\"（可选: perceptual / relative / saturation / absolute）",
      )
      None
    }
  }
}

///|
/// 把 0..1 的值四舍五入到 0..255 的整数（参考实现通常在 8 位域上给结果）。
fn quantise8(x : Double) -> Int32 {
  let scaled = x * 255.0
  let rounded = if scaled - scaled.to_int().to_double() >= 0.5 {
    scaled.to_int() + 1
  } else {
    scaled.to_int()
  }
  if rounded < 0 {
    0
  } else if rounded > 255 {
    255
  } else {
    rounded
  }
}

///|
/// 打印 LUT 结构，并做一次 CMYK 的 K 轴扫描（CMYK 打印机 profile 用）。
///
/// 输出格式：先若干行 `a2b <字段> <值>` 描述 LUT，再每行
/// `k <输入> <L> <a> <b>` 给出 CMYK=(0,0,0,k) 的 PCS Lab。
fn describe_lut(path : String) -> Unit raise {
  let profile = @moon_icc.Profile::parse(@fs.read_file_to_bytes(path))
  println("class \{profile.header.device_class}")
  println("colorspace \{profile.header.color_space}")
  println("pcs \{profile.header.pcs}")
  println(
    "version \{profile.header.major_version}.\{profile.header.minor_version}",
  )
  let table = profile.a2b(1)
  println("a2b_tag \{@moon_icc.intent_to_a2b_tag(1)}")
  println("a2b_type \{table.type_name()}")
  println("a2b_input_channels \{table.input_channels()}")
  println("a2b_output_channels \{table.output_channels()}")
  println("a2b_grid_points \{table.grid_text()}")
  println("a2b_bit_depth \{table.bit_depth()}")
  // PCS → 设备方向的结构（供外部 oracle 差分比对，见 tools/diff_oracle.py）
  let back = profile.b2a(1)
  println("b2a_tag \{@moon_icc.intent_to_b2a_tag(1)}")
  println("b2a_type \{back.type_name()}")
  println("b2a_input_channels \{back.input_channels()}")
  println("b2a_output_channels \{back.output_channels()}")
  println("b2a_grid_points \{back.grid_text()}")
  println("b2a_bit_depth \{back.bit_depth()}")
  // K 轴扫描：纯黑墨从 0 到 100%
  for i = 0; i <= 255; i = i + 17 {
    let v = i.to_double() / 255.0
    let lab = profile.device_to_lab(1, [0.0, 0.0, 0.0, v])
    println("k \{i} \{lab.l} \{lab.a} \{lab.b}")
  }
}

///|
/// 入口：
///   `moon run cmd/main -- parse <profile 路径>`
///   `moon run cmd/main -- transform <profile 路径>`
///   `moon run cmd/main -- link <源 profile> <目标 profile> [意图]`
///   `moon run cmd/main -- lut <LUT 型 profile 路径>`
///   `moon run cmd/main -- proof <源> <打样> <显示> [意图] [打样意图]`
///   `moon run cmd/main -- gamut <源 profile> <目标 profile> [意图]`
///
/// 参数按关键词扫描而非固定下标：不同后端下 `moon run` 传给程序的
/// argv 形状不同（js 后端会把脚本路径放进 argv），
/// 扫描关键词在两种后端下都成立。
fn main {
  let args = @env.args()
  let command_index = args.search_by(fn(a) {
    a == "parse" ||
    a == "transform" ||
    a == "link" ||
    a == "lut" ||
    a == "proof" ||
    a == "gamut"
  })
  match command_index {
    None => {
      println("用法:")
      println("  moon run cmd/main -- parse <icc-profile 路径>")
      println("  moon run cmd/main -- transform <icc-profile 路径>")
      println(
        "  moon run cmd/main -- link <源 profile> <目标 profile> [意图]",
      )
      println("  moon run cmd/main -- lut <LUT 型 profile 路径>")
      println(
        "  moon run cmd/main -- proof <源> <打样> <显示> [意图] [打样意图]",
      )
      println(
        "  moon run cmd/main -- gamut <源 profile> <目标 profile> [意图]",
      )
      println("")
      println("意图可选（默认 relative）:")
      println("  perceptual | relative | saturation | absolute")
    }
    Some(i) => {
      let command = args[i]
      // 各命令需要的 profile 路径数不同
      let needed_paths = match command {
        "proof" => 3
        "link" | "gamut" => 2
        _ => 1
      }
      if i + needed_paths >= args.length() {
        println("缺少 profile 路径参数")
        return
      }
      match command {
        "parse" =>
          describe(args[i + 1]) catch {
            e => println("解析失败: \{e}")
          }
        "transform" =>
          read_and_transform(args[i + 1]) catch {
            e => println("变换失败: \{e}")
          }
        "link" => {
          // 意图是可选的第 3 个参数；给了但无法识别则报错，不静默回退
          let intent_arg = if i + 3 < args.length() {
            Some(args[i + 3])
          } else {
            None
          }
          let intent = match intent_arg {
            None => 1
            Some(name) =>
              match parse_intent(name) {
                Some(v) => v
                None => {
                  println(
                    "无法识别的意图 \"\{name}\"（可选: perceptual / relative / saturation / absolute）",
                  )
                  return
                }
              }
          }
          read_and_link(args[i + 1], args[i + 2], intent) catch {
            e => println("链接失败: \{e}")
          }
        }
        "lut" =>
          describe_lut(args[i + 1]) catch {
            e => println("LUT 求值失败: \{e}")
          }
        "proof" => {
          let intent = match required_intent(args, i + 4, 1, "意图") {
            Some(v) => v
            None => return
          }
          let proof_intent = match
            required_intent(args, i + 5, 1, "打样意图") {
            Some(v) => v
            None => return
          }
          read_and_proof(
            args[i + 1],
            args[i + 2],
            args[i + 3],
            intent,
            proof_intent,
          ) catch {
            e => println("打样失败: \{e}")
          }
        }
        "gamut" => {
          let intent = match required_intent(args, i + 3, 1, "意图") {
            Some(v) => v
            None => return
          }
          read_and_gamut(args[i + 1], args[i + 2], intent) catch {
            e => println("色域判断失败: \{e}")
          }
        }
        _ => println("未知命令: \{command}")
      }
    }
  }
}
