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
/// 覆盖矩阵必须把所有设备类都列出来，且只用两种状态（本次实现 / 不作为目标）。
///
/// 评审明确不接受"暂不覆盖"这类含义不明的说法，因此这里用判据锁死用词：
/// 状态取值只允许两个，出现第三种即测试失败。
test "一致性: 覆盖矩阵列出全部设备类" {
  let rows = conformance_matrix()
  inspect(rows.length(), content="7")
  let mut implemented = 0
  let mut out_of_scope = 0
  for r in rows {
    match r.1 {
      "本次实现" => implemented = implemented + 1
      "不作为目标" => {
        out_of_scope = out_of_scope + 1
        // 只有命名色（nmcl）不作为目标，且必须给出理由
        if r.0 != "nmcl" {
          fail("\{r.0} 被标为不作为目标，但申报范围包含它")
        }
      }
      other =>
        fail(
          "\{r.0} 的状态取值非法: \{other}（只允许 本次实现/不作为目标）",
        )
    }
    if r.2.length() == 0 {
      fail("\{r.0} 没有给出边界说明")
    }
  }
  // 6 类本次实现（abst/link 用合成样本 + 解析式判据）；nmcl 不作为目标
  inspect(implemented, content="6")
  inspect(out_of_scope, content="1")
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
