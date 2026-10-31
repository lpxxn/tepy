# 第三方依赖

直接版本在 `pubspec.yaml` / Android Gradle 中固定，传递依赖由 `pubspec.lock` 与 Gradle 解析。发布时保留 APK 内的 Flutter NOTICES。

| 组件 | 版本 | 许可 / 来源 |
| --- | --- | --- |
| Flutter / Dart | 构建工具链 3.47.9 / 3.13.7 | [Flutter BSD-3-Clause](https://github.com/flutter/flutter/blob/master/LICENSE)、[Dart BSD-3-Clause](https://github.com/dart-lang/sdk/blob/main/LICENSE) |
| flutter_riverpod | 3.4.3 | [MIT / 官方仓库](https://github.com/rrousselGit/riverpod) |
| mqtt_client | 10.14.0 | [BSD-3-Clause / 官方仓库](https://github.com/shamblett/mqtt_client) |
| flutter_secure_storage | 11.2.0 | [BSD-3-Clause / 官方仓库](https://github.com/juliansteenbakker/flutter_secure_storage) |
| usb-serial-for-android | 3.11.0 | [MIT / 官方仓库](https://github.com/mik3y/usb-serial-for-android) |

USB 驱动作为固定版本 Android 库从 JitPack 获取，Tepy 没有修改其源码。许可原文保存在 `third_party/usb-serial-LICENSE.txt`。官方 `3.11.0` 标签源码归档 SHA-256 为 `9fc12819db958e0e83bc3ec276600758e42e049ec528341c43954768a0793af4`；本地发布目录附该归档。获取地址为 `https://codeload.github.com/mik3y/usb-serial-for-android/tar.gz/refs/tags/3.11.0`。

`fake_async`、`flutter_lints`、`flutter_test` 和 `integration_test` 只用于开发测试。界面使用系统中文字体与 Flutter Material Icons，不捆绑 Windows 字体文件；测试截图加载的本机字体不会进入 APK。
