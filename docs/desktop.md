# Qt 桌面管理工具

当前桌面版本 **0.1.1**，使用 Qt Widgets / QSerialPort / C++23；USB 管理需要 **固件 0.2.0 或以上**。Go 服务尚未实现。

## 启动

Windows 分发目录为 `dist/tepy-desktop/`，也可使用带版本的 `dist/tepy-desktop-0.1.1/`，双击其中的 `tepy-desktop.exe`。分发时保留整个目录，不能只复制 EXE。普通 HTTP / USB 管理不需要 Python 或 ESP-IDF；仅 USB 刷机需要已安装 esptool 的 Python。

界面分为设备概览、网络配置、蓝牙连接、固件管理。连接成功后自动收起连接表单，需要查看时展开“连接设置”。设备状态每三秒刷新，刷新不会覆盖尚未保存的配置编辑。

从 0.1.1 起，定时读取不再禁用按钮或表单，也不移动输入焦点。保存、配对和升级等用户操作优先于后台读取；进行中的写操作仍互斥，不会被轮询取消或自动重发。未变化的样式不重复应用，隐藏的 JSON 详情不重建；详情打开时保留滚动位置，正在选择文本复制时暂缓更新。升级桌面程序后需关闭旧窗口并重新打开，新功能不需要重新烧录固件。

![设备概览，使用自动测试的示例设备数据](assets/desktop-overview.png)

截图使用测试夹具数据，设备 ID 和连接状态不代表当前真实设备。

## HTTP 连接

1. 电脑连接设备所在局域网，或连接 Tepy 的配置热点。
2. 选择“HTTP 网络”，填入设备地址和管理口令，点击“连接并读取”。
3. 热点地址通常为 `http://192.168.4.1`；已配网设备使用实际 IP，例如 `http://192.168.50.240`。也可使用 `http://tepy-<完整 device_id>.local`。
4. 成功后查看 Wi-Fi、MQTT、BLE 和固件版本卡片；原始 JSON 在“查看状态详情”中。

这里填写 ESP32 的地址，MQTT Broker 地址在“网络配置”页填写。固件管理 HTTP 用于受信局域网或 WPA2 热点，不映射公网。客户端拒绝重定向；HTTPS 地址按系统信任规则校验证书，不提供忽略证书错误的开关。

## USB 连接

1. 使用支持数据的线连接 ESP32-S3 的**原生 USB Serial/JTAG 接口**。板上若有两个 USB 口，USB-to-UART 口目前只用于原有控制台／下载，未实现此串口管理协议。
2. 退出 `idf.py monitor`：在 monitor 窗口按 `Ctrl+]`。同一串口不能被两个程序同时打开。
3. 选择“USB 串口”，刷新列表并选择端口，例如 COM7，填写管理口令后连接。
4. 不需要先加入 Wi-Fi，即可读取状态、修改 Wi-Fi / MQTT、配对与重启。网络 OTA 仍使用 HTTP；USB 升级使用“USB 刷机与恢复”。

USB 连接也要求管理口令，不因插线而跳过鉴权。该接口只管理设备，不接收 `type_text` 或其他键盘动作。

若没有管理口令，先用 monitor 打开串口，在**设备运行时**长按 BOOT 三秒，读取 `Admin token`；退出 monitor 后再使用 Qt。不要在上电时一直按住 BOOT。Qt 不展示普通串口日志和恢复凭据，避免将密码放入常规日志窗口。

## 保存 Wi-Fi / MQTT

连接后自动读取脱敏配置；只有读取成功才可保存。扫描 Wi-Fi 后选择网络可填入 SSID，也可手动填写。

密码选项明确区分：

- **保留原值**：请求中省略密码字段，设备原密码保持不变。
- **设置新值**：填写新密码后发送；不会读取或回显原密码。
- **清除**：显式传空字符串，用于开放 Wi-Fi 或无密码的 Broker。管理口令不可清除。

MQTT 地址示例：`mqtt://192.168.50.10:1883` 或 `mqtts://broker.example.com:8883`。用户名和密码单独填写。自签 CA 可在“自定义 CA 证书”中导入 PEM，最长 8192 字节，不能包含私钥；为空时使用固件证书包。

“高级设置”包含 NTP、按键间隔和管理口令。改变管理口令后，工具在收到保存成功回复时更新当前连接口令；请自行妥善保存新口令。

点击“保存到设备”后，到“设备概览”点击“重启设备”。更换 Wi-Fi 后，按新的 IP 重新连接。保存超时表示结果未确认，不会自动重发；先重新读取配置。若请求同时修改了管理口令，重新连接时可能需要使用新口令。

## 蓝牙

开启 120 秒配对窗口，然后在 Mac 蓝牙设置连接 Tepy。若 Mac 显示六位码，在工具中提交。已有绑定的设备会自动重连；只有更换目标 Mac 时才使用“断开并清除绑定”。清除绑定前有明确确认。

键盘设置助理要求识别布局时，继续使用 MQTT 工具发送 `key z`、`key /` 并选择 ANSI，详见 [首次使用](getting-started.md)。Qt 当前负责管理；唤醒、文本和解锁动作继续使用仓库的 `tools/mqtt/tepy_cli.py`，不自动重试密码。

## 固件管理

**网络升级**：使用 HTTP 连接，选择 `tepy.bin`。客户端先检查 ESP32-S3、项目 `tepy` 和 4 MiB 大小上限；设备仍执行完整镜像校验。确认后显示上传进度，成功则重启。重新连接并查看版本，才能确认新固件已经运行。不要选择 `tepy-merged.bin`。

**USB 刷机与恢复**：选择同一次 IDF 构建的 `flasher_args.json`，保留清单引用的目录和 BIN，选择下载串口及含 esptool 的 Python。已安装 IDF 的本机可使用 `C:/Espressif/tools/python/v6.1/venv/Scripts/python.exe`。普通 Python 也可安装 `esptool>=5,<6` 后使用。

工具仅接受 Tepy 当前 N16R8 分区布局，写入四个分段，不主动擦除 NVS。开始烧录前释放本工具串口；外部 monitor 需先退出。esptool 输出显示于烧录区域。操作完成前阻止关闭窗口，结果不确定时不自动重复。

镜像校验和恢复细节见 [OTA 与串口恢复](ota.md)。

## 源码、构建与测试

源码独立于固件：

```text
apps/desktop-qt/
├── CMakeLists.txt
├── src/
│   ├── main.cpp                 # QApplication / 启动检查
│   ├── main_window.*            # 页面组装与交互
│   ├── ui.*                     # 卡片、图标、配色与公共样式
│   ├── config_form.*            # 配置字段与密码操作
│   ├── device_client.*          # HTTP / USB 管理请求
│   ├── serial_port.*            # 独立线程中的 QSerialPort
│   ├── protocol.*               # 分帧、路由、镜像和烧录清单
│   └── flash_job.*              # 异步 esptool 进程
└── tests/desktop_tests.cpp
```

依赖：Qt 6.8 以上的 Widgets / Network / SerialPort / Test，CMake 3.22 以上、Ninja、C++23 编译器。本机使用 Qt 6.12.0。

在仓库根目录：

```powershell
.\tools\dev\desktop.ps1             # 构建并运行自动测试
.\tools\dev\desktop.ps1 -Run        # 构建、测试并打开窗口
.\tools\dev\desktop.ps1 -Package    # 生成含 Qt DLL / 插件的运行目录
```

脚本默认路径对应本机安装，可通过 `-QtPath` 和 `-CompilerPath` 修改。Qt Creator 直接打开该目录的 `CMakeLists.txt` 并选择已安装 SerialPort 的 Kit。

其他平台可独立构建：

```sh
cmake -S apps/desktop-qt -B apps/desktop-qt/build -DCMAKE_PREFIX_PATH=/path/to/Qt
cmake --build apps/desktop-qt/build
ctest --test-dir apps/desktop-qt/build --output-on-failure
```

macOS / Linux 尚未构建与实测，不将共用 QSerialPort 源码等同于平台验收通过。

Qt 测试覆盖流式分帧、HTTP 请求／鉴权／重定向错误、密码省略与显式清除、UTF-8 长度、镜像和 NVS 区域保护、上传字节、超时不重试、窗口初始化与连接读取流程。测试报告在 `apps/desktop-qt/build/desktop-tests.txt` / `.xml`。

可选硬件检查需要显式设置环境变量：

```powershell
$env:TEPY_TEST_SERIAL = 'COM7'
$env:TEPY_TEST_APPLICATION = (Resolve-Path firmware/build/tepy.bin).Path
.\tools\dev\desktop.ps1
Remove-Item Env:TEPY_TEST_SERIAL, Env:TEPY_TEST_APPLICATION
```

串口检查只发送一个故意错误的管理口令，要求真实固件返回拒绝，不写配置或产生按键。正常配置写入、配对及 OTA 端到端验收需另行进行，见 [验证记录](testing.md)。
