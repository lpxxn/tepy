# OTA 与串口恢复

分区：NVS、OTA 元数据、PHY、`ota_0` 与 `ota_1`（各 4 MiB），其余空间保留。无独立网页分区，避免升级后网页和 API 不匹配。

首次通过 USB 烧录完整工程；网页只上传 `firmware/build/tepy.bin`，不能上传合并镜像或 bootloader。

上传要求管理口令、原始二进制和 Content-Length。升级与输入互斥。写入非运行分区后执行 ESP-IDF 镜像校验，再核对项目标识 `tepy`，有效后修改启动分区并重启。接收断开、镜像不完整、目标不符或空间不足不切换分区。镜像校验不是发布者签名验证；首版以管理口令和受信网络控制上传权限。

新镜像首次启动必须完成 NVS、配置、BLE、网络、MQTT 客户端、HTTP 及启用的串口管理接口的本地初始化，再确认有效。Broker 离线、无 Wi-Fi 和 Mac 睡眠不影响本地自检成功。初始化失败重启，由 bootloader 回滚。升级期间断电按双分区 OTA 机制恢复。

Qt 工具在“固件管理”页提供同一个 HTTP OTA 接口。客户端先检查应用镜像的 ESP32-S3 标识、项目名和大小，设备仍执行完整镜像校验。上传完成只表示设备已接受更新，重新连接后确认实际启动版本。

Qt 串口刷机读取 IDF 的 `flasher_args.json`，分别写入 bootloader、分区表、OTA 数据和应用，不写 NVS 所在的 `0x9000–0x18fff`。**不要用带填充空隙的合并 BIN 做日常保留配置升级**：把整个合并文件从 `0x0` 连续写入会连同空隙一起覆盖。合并 BIN 用于首次安装；日常使用 OTA 或分段清单。

恢复：使用 BOOT / RESET 进入开发板下载模式，运行 `idf.py -p PORT flash monitor`。普通刷机保留 NVS 和绑定。不建议直接 `erase-flash`，因为它会删除配置及蓝牙绑定；只有明确需要出厂重置时手工执行。

构建产物：`tepy.bin`（OTA）、`tepy-merged.bin`（首次安装，执行 merge-bin 生成）、`flasher_args.json` 和对应 `dependencies.lock`。构建产物不提交 Git。

生成可分发的固件目录：

```powershell
.\tools\dev\idf.ps1 merge-bin -o tepy-merged.bin
.\tools\dev\package-firmware.ps1
```

脚本先核对源码版本、应用版本及合并镜像中的应用字节一致，再生成 `dist/firmware/<version>/`，包含应用、合并镜像、分段清单及文件、分区表、依赖锁与 SHA256SUMS。
