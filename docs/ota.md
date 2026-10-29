# OTA 与串口恢复

分区：NVS、OTA 元数据、PHY、`ota_0` 与 `ota_1`（各 4 MiB），其余空间保留。无独立网页分区，避免升级后网页和 API 不匹配。

首次通过 USB 烧录完整工程；网页只上传 `firmware/build/tepy.bin`，不能上传合并镜像或 bootloader。

上传要求管理口令、原始二进制和 Content-Length。升级与输入互斥。写入非运行分区后执行 ESP-IDF 镜像校验，再核对项目标识 `tepy`，有效后修改启动分区并重启。接收断开、镜像不完整、目标不符或空间不足不切换分区。镜像校验不是发布者签名验证；首版以管理口令和受信网络控制上传权限。

新镜像首次启动必须完成 NVS、配置、BLE、网络、MQTT 客户端和 HTTP 的本地初始化，再确认有效。Broker 离线、无 Wi-Fi 和 Mac 睡眠不影响本地自检成功。初始化失败重启，由 bootloader 回滚。升级期间断电按双分区 OTA 机制恢复。

恢复：使用 BOOT / RESET 进入开发板下载模式，运行 `idf.py -p PORT flash monitor`。普通刷机保留 NVS 和绑定。不建议直接 `erase-flash`，因为它会删除配置及蓝牙绑定；只有明确需要出厂重置时手工执行。

构建产物：`tepy.bin`（OTA）、`tepy-merged.bin`（首次安装，执行 merge-bin 生成）、`flasher_args.json` 和对应 `dependencies.lock`。构建产物不提交 Git。
