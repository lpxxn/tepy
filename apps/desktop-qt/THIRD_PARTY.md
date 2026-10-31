# Desktop 第三方依赖

桌面程序使用 Qt Core / Widgets / Network / SerialPort / Test。0.3.0 增加 Qt MQTT，沿用同一 Qt 事件循环与 TLS 后端。

本机补建的 Qt MQTT：

- 版本：6.12.0，Qt 官方仓库标签 `v6.12.0`。
- 源码：[qt/qtmqtt](https://github.com/qt/qtmqtt/tree/v6.12.0)。
- 源码归档：https://codeload.github.com/qt/qtmqtt/tar.gz/refs/tags/v6.12.0
- SHA-256：`55b2ac2938c6057aebd1df5366860d277ebda445f960111fba0998fedeced700`。
- 模块许可：LicenseRef-Qt-Commercial OR GPL-3.0-only，原始文本见源码 `LICENSES/`；[官方模块说明](https://doc.qt.io/qt-6.12/qtmqtt-index.html#licenses-and-attributions)。

`tools/dev/desktop-deps.ps1` 在工作区 `.venv/qtmqtt/` 下载、校验、构建和安装，不写系统 Qt 目录。源码及依赖安装目录被 Git 忽略。Windows 0.3.0 分发包保留 Qt MQTT 源码归档、许可文件和桌面构建源码。
