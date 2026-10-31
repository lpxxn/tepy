# Tepy Desktop 0.3.0

Qt Widgets / QSerialPort / C++23 设备管理工具，提供状态概览、Wi-Fi / MQTT 配置、蓝牙配对、网络 OTA 和 USB 分段刷机。

0.3.0 增加 MQTT“键盘控制”：唤醒、文字、组合键和唤醒后单次解锁输入，分别展示 HID 回执与 Mac 反馈。连接地址、设备 ID、代理 ID 和证书路径记在本机；服务口令及 Broker 密码由 Windows Credential Manager／macOS Keychain 保存。键盘输入不保存、不自动重试。详见 [键盘控制与连接记忆](../../docs/keyboard-control.md)。

0.2.0 增加“Mac 状态”页，连接 Go 服务的只读 HTTP，查看在线、锁定、Tepy 键盘注册、MQTT 和电源事件。服务地址与口令独立于 ESP32；2026-10-31 当前地址为 `http://192.168.50.246:18765`，口令取自 Mac 服务 TOML 的 `http.token`。详见 [Mac 服务文档](../../docs/macos-agent.md)。

0.1.1 修复自动刷新导致的闪烁和按钮短暂变灰：后台读取不锁定界面，用户操作可优先执行，未变化的样式不重复应用；查看状态详情时保留滚动位置和选中文本。固件无需为此更新。

Windows 使用 `dist/tepy-desktop-0.3.0/tepy-desktop.exe`，分发时保留全部 DLL 与插件目录。选择 HTTP 地址或 USB 串口，填写设备管理口令后连接。USB 配置需要固件 0.2.0 和 ESP32-S3 原生 USB，先退出占用串口的 monitor。

管理口令可在设备运行时长按 BOOT 三秒，从 monitor 输出中获取；读取后退出 monitor，再打开 Qt。密码默认保留，只有显式选择替换或清除才修改。保存配置后重启设备。

在仓库根目录运行 `tools/dev/desktop.ps1 -Run` 构建、测试并启动；`-Package` 生成 Windows 运行包。依赖 Qt 6.8+ Widgets / Network / SerialPort / Mqtt / Test 及 C++23 编译器。本机 Qt MQTT 6.12.0 可用 `tools/dev/desktop-deps.ps1` 在工作区构建，来源和许可见 [第三方依赖](THIRD_PARTY.md)。普通管理与键盘控制不依赖 Python；USB 刷机需要含 esptool 的 Python 和 IDF 生成的 `flasher_args.json`。

完整用法、目录与测试说明见 [桌面工具文档](../../docs/desktop.md)。

本轮验证 Windows；macOS / Linux 尚未进行平台构建验收。Mac 状态页只观察状态，键盘动作在独立控制页显式执行。左侧“清除保存的连接”可移除本机保存的地址与服务口令，不修改设备配置。



轮询在后台刷新，保留输入焦点和按钮状态；点击保存等操作时优先处理，不会丢掉点击。后台刷新保持按钮、输入焦点和选区稳定，用户操作优先执行