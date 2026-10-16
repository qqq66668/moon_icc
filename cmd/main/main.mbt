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
/// 入口：
///   `moon run cmd/main -- parse <profile 路径>`
///   `moon run cmd/main -- transform <profile 路径>`
///
/// 参数按关键词扫描而非固定下标：不同后端下 `moon run` 传给程序的
/// argv 形状不同（js 后端会把脚本路径放进 argv），
/// 扫描 `parse`/`transform` 关键词在两种后端下都成立。
fn main {
  let args = @env.args()
  let command_index = args.search_by(fn(a) { a == "parse" || a == "transform" })
  match command_index {
    None => {
      println("用法:")
      println("  moon run cmd/main -- parse <icc-profile 路径>")
      println("  moon run cmd/main -- transform <icc-profile 路径>")
    }
    Some(i) => {
      let command = args[i]
      // 路径是关键词之后的下一个参数
      if i + 1 >= args.length() {
        println("缺少 profile 路径参数")
        return
      }
      let path = args[i + 1]
      match command {
        "parse" => describe(path) catch { e => println("解析失败: \{e}") }
        "transform" =>
          read_and_transform(path) catch {
            e => println("变换失败: \{e}")
          }
        _ => println("未知命令: \{command}")
      }
    }
  }
}
