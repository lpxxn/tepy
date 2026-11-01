# Flutter Mac 诊断、密码与固件管理

适用 Tepy Flutter **0.3.0+7**，Android 与 Windows 共用功能。导航为“状态 / 操作 / Mac / 设备 / 固件 / 连接”。

## Mac 状态与诊断

在“连接”页填写实际 Broker、ESP32 ID 和 Mac Agent ID，连接后打开“Mac”。

- **状态**：屏幕锁定、控制台、登录、电源监听、目标 HID、Agent 版本与会话。
- **诊断**：Go Agent 0.2.0 的结构化检查、状态、说明和错误代码。报告过期后显示等待，不保留绿色结论。
- **事件**：当前 Agent 会话的最近 200 条内存事件，可按会话、电源、键盘和连接筛选，最新在上方。Agent 重启会开始新历史。

数据通过 `tepy/macos/<agent_id>/{state,availability,diagnostics,events}` 接收，不依赖 Mac 的 HTTP / SSH 地址。Mac 改 IP 后无需修改客户端。历史和诊断必须匹配当前状态的 session；旧 retained 历史不能证明设备在线。旧版 Agent 没有新主题时，页面提示等待；Broker 拒绝可选主题时提示 ACL，不影响原有键盘主题连接。

这页读取后台诊断，不触发远程 doctor，不执行 Mac 命令。诊断不能代替解锁流程对最新锁定状态和 HID 的检查。

## 保存 Mac 登录密码

1. 先在“连接”页确定 Broker、ESP32 ID 与 Mac Agent ID。
2. 打开“操作”，找到 **Mac 登录密码 → 设置并保存**。
3. 输入登录密码，选择默认等待秒数与是否回车，点击“保存到本机 JSON”。
4. 下次“唤醒并输入解锁”默认选择“使用已保存密码”，点击“执行一次”即可。也可取消勾选，临时手动输入。

按用户选择，密码使用**明文 JSON**，不使用系统钥匙串或安全存储。文件为应用支持目录下的 `mac-passwords.json`；“操作”页显示完整实际路径，可复制查看。Windows 使用当前用户的应用数据目录；Android 使用应用私有目录，普通文件管理器可能无法直接访问，调试设备可通过开发工具查看。当前没有实现 iOS / macOS 原生应用。

文件内容示例仅含虚构密码：

```json
{
  "v": 1,
  "profiles": [
    {
      "broker": "mqtt://broker.example:1883",
      "agent_id": "mac-example",
      "device_id": "aabbccddeeff",
      "password": "ExampleOnly!",
      "press_enter": true,
      "wait_seconds": 3
    }
  ]
}
```

每条记录绑定 Broker（协议、主机、有效端口）、Mac Agent ID 和 ESP32 ID。更换任一目标需要对应条目，避免误用其他 Mac 的密码。最多 32 条、文件不超过 64 KiB；密码支持美式 ABC 布局可打印 ASCII 1–512 字符，等待 0–30 秒。修改文件后点“重新读取 JSON”；每次真正执行前仍重新读文件。格式错误保留原文件并提示，不自动清空。

“清除保存的密码”只移除当前目标。此文件包含可直接读取的密码，按本机配置自行保管；源码、发布包和日志不包含它。普通“发送文字”及手动解锁输入仍不保存。Broker 与 ESP32 管理口令继续使用原有系统安全存储，和此文件独立。

解锁仍需用户确认，只发送一次，不自动重试密码；取消、后台、网络断开或 HID 条件变化会终止后续步骤。适用已启动 macOS 的锁屏，不承诺 FileVault 开机前解锁。

## 网络 OTA

1. 确认手机 / Windows 可访问 ESP32 的管理 HTTP 地址；只接通 MQTT 不代表能直连管理接口。
2. 打开“固件”，填写 `http://ESP32-IP`、目标设备 ID、ESP32 管理口令，点击“连接并读取版本”。可使用当前 MQTT 状态里的 ESP32 地址。
3. 点“选择应用镜像”，在系统文件选择器中打开 `firmware/build/tepy.bin`，或固件发布目录中的应用镜像。
4. 核对设备 ID、当前版本、镜像版本、大小和 SHA-256，点击“上传并升级”，在确认框中再次核对目标。
5. 保持供电和前台网络连接。上传后等待设备重启；只有读到**新会话与匹配的运行版本**才显示确认成功。

只接受 ESP32-S3、项目名 `tepy`、不超过 4 MiB 且带校验哈希的普通 IDF 应用镜像。客户端检查段边界、校验和与附加 SHA-256，设备继续执行自己的 OTA 校验。不要选择合并烧录镜像、bootloader、分区表或其他项目的 bin。完整性校验不等同于发布者签名认证；此版本未处理 Secure Boot 签名镜像。

进度表示镜像上传进度，100% 后仍需确认重启与版本。断网、取消、后台或超时不会自动重传；先重新读取版本再决定下一步。“停止等待”不能撤回已写入设备的镜像，设备可能已经开始重启。新会话版本不匹配时提示可能回滚，需要人工检查。

OTA 不依赖 Mac Agent 在线，但升级期间暂停本应用键盘和 USB 管理操作。接口使用 Bearer 管理口令，不跟随 HTTP 重定向；HTTPS 保留证书与主机名验证。现有固件管理接口通常为局域网 HTTP。可单独记住管理连接。首轮不含 USB ROM 刷机、自动下载或批量升级。

## 代码阅读

参见 [学习导读](flutter-learning.md)。核心位置（相对 `apps/mobile-flutter`）：

| 功能 | 模型 / 数据 | Riverpod / 界面 |
| --- | --- | --- |
| Mac 观察 | `domain/agent_observations.dart` | `application/session_controller.dart`、`presentation/screens/mac_screen.dart` |
| 明文密码 | `data/mac_password_store.dart` | `application/mac_password_controller.dart`、`presentation/widgets/mac_password_settings.dart` |
| 网络 OTA | `domain/firmware_image.dart`、`data/firmware_client.dart` | `application/firmware_controller.dart`、`presentation/screens/firmware_screen.dart` |

对应测试为 `observations_test.dart`、`mac_password_test.dart`、`firmware_test.dart` 与界面 / MQTT 线协议测试。HTTP 测试使用本机测试服务，不升级真实设备；原生存储集成检查使用随机测试目录，不接触用户密码文件。
