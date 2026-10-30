# 第三方算法说明

歌词的 QRC 变体 DES 字节变换改编自 AnyListen Online Metadata 0.4.6 的 qrcDecode 实现，使用 Apache-2.0 许可证。源码仓库：https://github.com/any-listen/any-listen-extension-online-metadata 。改动包括隔离为无网络的 JavaScriptCore 字节变换，以及由 Swift 执行有输出上限的解压。

KRC、酷我 Lyricx、咪咕 MRC 的 Swift 解码及平台格式转换参考同仓库算法与协议。保留其 QRC 两处非标准 S-box 值。许可证全文见 [Apache-2.0](online-metadata-Apache-2.0.txt)。
