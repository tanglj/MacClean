# 应用图标

Mac Clean 的图标由 AppKit 绘制，主体为蓝色圆角背景、白色扫刷与星芒。无需外部图片服务或字体。

- `AppIcon.png`：1024 × 1024 透明背景原图。
- `AppIcon.icns`：macOS 应用图标。
- `Assets.car`：由 Xcode `actool` 编译的现代 macOS 图标资源，供 Finder、系统设置和 LaunchServices 使用。
- `Info.plist`：应用包元数据，通过 `CFBundleIconName` 引用 `AppIcon`，并保留 `CFBundleIconFile` 兼容旧系统。

重新绘制原图：

```sh
swift Scripts/GenerateAppIcon.swift Resources/AppIcon.png
python3 Scripts/BuildAppIcon.py
```

图标构建所需的标准尺寸和 Retina 尺寸 PNG 会在临时目录中生成。使用 `xcrun` 可找到当前选用的 Xcode 中的 `actool`，用于生成 `Assets.car`。

打包时将 `Info.plist` 放入应用包的 `Contents/`，将 `AppIcon.icns` 和 `Assets.car` 放入 `Contents/Resources/`，然后重新签名。图标显示可能被 Finder、系统设置或 LaunchServices 缓存，重新注册应用后生效。
