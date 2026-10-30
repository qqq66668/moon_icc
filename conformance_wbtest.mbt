///|
/// 一致性检查的测试。
///
/// 覆盖「标准版本与必需行为的完整覆盖目标」这一条评审意见：
/// 宣称的支持必须有可执行的检查，而不是文档里的一句话。

///|
/// 真实 profile 的必需 tag 应当齐备，且设备类判定正确。
test "一致性: 真实 profile 的必需 tag 齐备" {
  let cases : Array[(String, String)] = [
    ("srgb.icc", "mntr"),
    ("display.icc", "mntr"),
    ("cmyk_printer.icc", "prtr"),
    // test4.icc 是 Little-CMS 的 colorSpace 类样本（v4），不是显示器类
    ("test4.icc", "spac"),
    ("xyz_lut.icc", "mntr"),
  ]
  for c in cases {
    let report = load_profile(c.0).conformance()
    if report.device_class() != c.1 {
      fail("\{c.0} 的设备类应为 \{c.1}，实际 \{report.device_class()}")
    }
    if !report.ok() {
      let missing = report.missing()
      let mut names = ""
      for m in missing {
        names = names + " " + m
      }
      fail("\{c.0} 缺少必需 tag:\{names}")
    }
    if !report.transform_supported() {
      fail(
        "\{c.0} 属于本次实现范围的设备类，却未报告为已交付",
      )
    }
  }
}

///|
/// 覆盖矩阵必须列出全部 7 个设备类，且**全部**为「本次实现」。
///
/// 这是对第四次驳回的直接锁：命名色（`nmcl`）一旦被重新标成「不作为目标」
/// 或其他第三态，本测试立刻失败。
test "一致性: 覆盖矩阵的 7 个设备类全部为本次实现" {
  let rows = conformance_matrix()
  inspect(rows.length(), content="7")
  let mut implemented = 0
  for r in rows {
    if r.1 != "本次实现" {
      fail(
        "\{r.0} 的状态是 \{r.1}，但 ICC v4.3 的 7 个设备类本次全部属于项目终点",
      )
    }
    implemented = implemented + 1
    if r.2.length() == 0 {
      fail("\{r.0} 没有给出边界说明")
    }
  }
  inspect(implemented, content="7")
}

///|
/// 必需 tag 清单按设备类区分：抽象与 device link 不要求 `wtpt`。
test "一致性: 必需 tag 随设备类变化" {
  let mntr = required_tags_for_class("mntr")
  inspect(mntr.length(), content="3")
  let abst = required_tags_for_class("abst")
  inspect(abst.length(), content="2")
  let link = required_tags_for_class("link")
  inspect(link.length(), content="2")
}

///|
/// 非抽象 profile 调用 `apply_abstract` 必须报错，而不是静默给出错误结果。
test "一致性: 对非抽象 profile 调用抽象变换会报错" {
  let cmyk = load_profile("cmyk_printer.icc")
  try {
    let _ = cmyk.apply_abstract(1, d50_white)
    fail(
      "CMYK 打印机 profile 不是抽象 profile，不应接受抽象变换",
    )
  } catch {
    BadTagData(..) => ()
    e => fail("期望 BadTagData，实际: \{e}")
  }
  inspect(cmyk.is_abstract(), content="false")
  inspect(cmyk.is_device_link(), content="false")
}
