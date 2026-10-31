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

`fake_async`、`flutter_lints`、`flutter_test` 和 `integration_test` 只用于开发测试。界面使用内置 Tepy Sans 和 Flutter Material Icons；不打包 Windows 系统字体。Tepy Sans 是 Noto Sans SC 的离线子集，原始版权及 SIL OFL 1.1 许可保存在 `assets/fonts/OFL.txt`，应用内“开源许可”可查看。保留 GB2312 常用字符、拉丁字符、标点和界面用字，罕见字使用系统回退。

源文件：[Google Fonts Noto Sans SC](https://github.com/google/fonts/tree/main/ofl/notosanssc)，`NotoSansSC[wght].ttf` 的 SHA-256 为 `a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da`。派生字体内部名称为 Tepy Sans，生成脚本为 `tools/dev/subset-flutter-font.py`（fonttools 4.68.0）。字体无运行时下载。Windows 串口桥直接使用系统 SetupAPI / Win32，不引入另一套串口依赖。
