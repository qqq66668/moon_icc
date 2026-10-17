# 测试用 ICC profile 的来源与许可

本目录下的 profile **仅用于测试**，不作为色彩管理数据使用。

| 文件 | 来源 | 许可 / 说明 |
|------|------|-------------|
| `srgb.icc` | `C:\Windows\System32\spool\drivers\color\sRGB Color Space Profile.icm` | 随 Windows / ICC 分发的 sRGB v2.1 profile，仅本地测试用，未在仓库中主张任何权利 |
| `display.icc` | 同上目录的显示器 profile（v2.2） | 同上 |
| `cmyk_printer.icc` | 同上目录的打印机 profile（v2.0，CMYK，PCS 为 Lab） | 同上 |
| `test4.icc` | [Little-CMS](https://github.com/mm2/Little-CMS) 仓库 `testbed/test4.icc` | Little-CMS 以 **MIT 许可**发布；该文件自带说明 "Test profile, not suitable for real use"（见其 `desc` 与 `cprt` 字段） |

## 为什么需要 `test4.icc`

本机（以及 Windows 自带的驱动目录）里的 LUT 型 profile **全部是 ICC v2**（`mft1`/`mft2`）。
ICC v4 的 `mAB `（`lutAToBType`）与 `mBA `（`lutBToAType`）**没有样本就无法建立判据**，
所以引入了 Little-CMS 测试套件里这个 v4.2 的 profile：

- 设备色空间 `RGB `，PCS 为 `Lab `，设备类别 `spac`；
- `A2B0`（17³ CLUT）、`A2B1`（2³ CLUT + 参数曲线 + 矩阵）、
  `B2A0`（17³ CLUT）、`B2A1`（2³ CLUT + 矩阵 + 参数曲线）**四个 tag 都是 v4 类型**。

它覆盖了实现里最容易出错的两处：

1. `mAB `/`mBA ` 的**矩阵段没有类型签名头**（偏移直接指向 9 个 `s15Fixed16`）；
2. 内嵌曲线段**没有长度字段**（类型签名后的 4 字节是保留位），
   段长度只能按类型从内容推算，且 `para` 类型有 1/3/4/5/7 个参数五种形态。

## MIT 许可声明（Little-CMS）

```
MIT License

Copyright (c) 2023 Marti Maria Saguer

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject
to the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
