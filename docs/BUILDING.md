# 构建与安装

拍点是 iOS 17+ 原生音乐播放器，工程为 `PaiDian.xcodeproj`，主 Scheme 为 `PaiDian`。发布版本以 Xcode 27 / iOS 27 SDK 构建；其他工具链版本未逐一验证。

## 从源码安装

1. 用 Xcode 打开工程，选择 `PaiDian` Scheme。
2. 在应用 Target 的 Signing & Capabilities 中选择自己的 Team；首次安装时将 Bundle Identifier 改为自己可用的唯一值。
3. 连接 iPhone，完成系统要求的配对、信任和开发者模式设置，选择该设备后 Run。
4. 如需覆盖旧安装，继续使用原来的 Bundle Identifier 和 Team，不要先卸载应用。

默认 Bundle ID `org.anylisten.AnyListen` 和内部 `AnyListen` 存储目录为兼容既有安装保留。显示名称为“拍点”，可执行文件与模块名称为 `PaiDian`。工程生成脚本会保留已有 Bundle ID 和签名设置，个人证书与配置文件不随仓库分发。

## 安装 Release IPA

Release 附件 `PaiDian-v1.0.1-unsigned.ipa` **未签名，不能直接安装**。请使用支持 IPA 重新签名的侧载工具，以自己的签名身份签名后安装。它不含维护者的证书、描述文件或设备授权。

## 本地检查

```sh
zsh scripts/run_core_tests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project PaiDian.xcodeproj -scheme PaiDian \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Simulator CODE_SIGNING_ALLOWED=NO build-for-testing
```

仅安装 SDK 可以编译，但运行模拟器需要额外安装相应 iOS 运行时。普通 Scheme 不运行真实音源联网测试或真机音源批量导入。`LiveSources`、`ImportSources`、`Screenshots` 是显式操作 Scheme，分别用于联网验证、测试装置导入和发布截图；请阅读对应测试代码后再运行。

新增 Swift 文件后运行 `python3 scripts/generate_project.py`。图标转换命令和母版说明见 [品牌资源](../resources/branding/README.md)。生成未签名 IPA 使用 `zsh scripts/package_release.sh`。

应用为兼容第三方 HTTP 音源启用了 ATS 任意加载，HTTPS 仍使用系统证书校验；JavaScriptCore 无法中断同步死循环，仅导入可信脚本。
