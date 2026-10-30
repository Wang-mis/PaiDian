# 拍点图标

`paidian-icon-master.png` 是已选定的 ImageGen 概念原图：蓝色背景、橙色唱片、奶白节奏线，1254 × 1254，无透明通道。

在仓库根目录执行以下命令，从母版生成 1024 × 1024、sRGB、无透明通道的正式 AppIcon：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift -module-cache-path build/HostModuleCache scripts/generate_icon.swift
```

生成脚本只进行缩放与编码，不调用图像生成服务，也不添加圆角或修改构图。iOS 负责图标的系统圆角。
