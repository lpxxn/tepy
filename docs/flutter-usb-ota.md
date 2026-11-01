# Flutter USB 固件升级

适用 **Flutter 0.4.0+9 / ESP32 固件 0.3.0+**。Android 通过 USB OTG，Windows 通过 COM 串口，均使用 ESP32-S3 的原生 USB Serial/JTAG 数据口。

## 首次准备

已有 0.2.x 固件只支持 USB 配置，尚不理解升级命令。先在 Flutter 的“固件 → 网络 OTA”、网页或 Qt 上传新版本 `tepy.bin`，也可在 IDF 环境执行 `idf.py -p COM7 flash`。这一步完成一次后，后续日常应用升级可以完全离线走 USB。

首次更新推荐使用发布目录 `dist/firmware/0.3.0/tepy.bin`。合并镜像用于首次安装，不作为此页面的输入；恢复损坏固件仍使用现有 IDF / Qt 刷机工具。USB 应用升级不会写 NVS、蓝牙绑定、分区表或 bootloader。

## 操作步骤

1. 将 ESP32 原生 USB 口接到电脑，或通过 OTG 数据线接手机，保持供电。
2. 打开“设备”页，刷新并选择设备，填写原来的设备管理口令后连接。Android 出现 USB 授权时由用户允许；Windows 需退出占用 COM 的 monitor 或其它工具。
3. 打开“固件”，选择 **USB 升级**。核对目标 ESP32 ID，点击“通过 USB 读取版本”。旧固件会提示先更新 USB 升级能力。
4. 选择 `tepy.bin`，核对镜像版本、大小和 SHA-256。网络 OTA 与 USB 共用同一份镜像和客户端检查。
5. 点击“上传并升级”，在确认框核对方式、设备、当前版本和镜像版本，再点击“开始升级”。
6. 进度到 100% 后仍需设备检查和重启。看到“镜像已校验并接受”后，前往“设备”页刷新并重新连接 USB；必要时重新授权或选择新枚举的端口。
7. 回到“固件”页：只有目标 ID 一致、启动会话改变且实际运行版本匹配时，才显示版本已确认。版本不匹配会提示可能回滚，不自动重传。

不需要连接 MQTT、Wi-Fi、NTP 或 Mac。运行版本可以与镜像版本相同，但仍需要新的启动会话确认重启。重启期间 USB 端口可能消失或重新枚举，因此此版由用户重新连接，避免擅自连接另一块设备。

## 中断与取消

客户端每块只发送一次，收到准确偏移回执后继续；进度表示设备已确认接收的字节。取消或切到后台会停止上传，未收到完整回执时不能据此判断设备最终版本。尽力发送 abort；断线时设备在 30 秒无有效数据后丢弃未完成事务并释放维护锁，事务总时限为 10 分钟。

完整数据、原始文件 SHA-256、IDF 镜像校验和项目 `tepy` 检查通过后才切换启动分区。若 finish 已被设备处理，取消不能撤回更新；先重新连接读取版本。不要通过自动重试解决未知结果，不自动重复输入密码。等待重连确认是只读状态，可跨后台保留；手动点“停止等待”可结束观察。

系统文件选择器暂时切走应用时保留 USB，但不执行上传；平常进入后台仍关闭 USB。数据线拔出会终止当前流程。实际 Android OTG 链路与断电回滚仍需实机验收。

## 协议与代码

沿用 `@tepy:` JSON 行协议和每请求管理口令，帧上限保持 20000 字节，新增方法：

| 方法 | 参数 | 成功结果 |
| --- | --- | --- |
| `ota.begin` | device_id、session（boot_session）、size、sha256 | upload_id、next_offset=0、max_chunk_bytes=3072 |
| `ota.write` | upload_id、offset、data（Base64，原始块最多 3072 字节） | next_offset |
| `ota.finish` | upload_id | ok=true、rebooting=true |
| `ota.abort` | upload_id | next_offset=0 |

`boot_session` 每次启动随机生成，独立于原 MQTT `session`。MQTT 动作继续使用连接 session，USB 升级绑定启动 session；Broker 重连不视为设备重启。状态中的 `usb_ota: {"v":1,"max_chunk_bytes":3072}` 声明能力。HTTP OTA 也优先用 boot_session 核对重启，兼容旧固件的 session。

设备在整个上传期间持有维护锁，拒绝键盘动作、另一个 OTA 和配置写入。错误 ID 不接管当前事务；正确 ID 的错误偏移、越界块、写入失败、哈希失败或不完整 finish 会终止事务。错误码包括 `busy`、`wrong_device_session`、`invalid_upload`、`invalid_upload_id`、`invalid_chunk`、`incomplete_upload`、`digest_mismatch`、`invalid_image` 和 `wrong_project`。示例与 Schema 位于 `protocol/v1`，示例数据仅用于阅读，不能作为真实镜像重放。

| 层 | 文件与职责 |
| --- | --- |
| Flutter 协议 | `lib/domain/serial_firmware.dart`：状态校验、分块、回执、取消 |
| Flutter 串口 | `application/usb_controller.dart`：同一鉴权连接与维护租约 |
| Flutter 流程 | `application/firmware_controller.dart`：两种通道、进度和重连核对 |
| 固件串口 | `tepy_serial/serial.cpp`：鉴权后解析升级方法、Base64 解码 |
| 固件事务 | `tepy_serial/serial_upload.cpp`：偏移、时限和维护锁，可主机测试 |
| 固件写入 | `tepy_ota/ota.cpp`：备用分区、PSA SHA-256、校验和激活，HTTP / USB 共用 |

Flutter 路径相对 `apps/mobile-flutter`，固件路径相对 `firmware/components`。原生 Kotlin / C++ 桥继续只传 USB 字节，不解析固件升级协议。
