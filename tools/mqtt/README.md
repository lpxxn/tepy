# MQTT 客户端

安装 `requirements.txt` 后运行 `python tools/mqtt/tepy_cli.py --help`。公共参数放在子命令前；用户名和密码从 `TEPY_MQTT_USERNAME` / `TEPY_MQTT_PASSWORD` 环境变量读取。

首次使用请按 [配网重启后的完整操作流程](../../docs/getting-started.md#配网并重启后) 完成网页状态检查、Mac 蓝牙配对、普通文字测试，再验证睡眠唤醒和密码输入。该流程包含 PowerShell 认证配置与当前设备的地址示例。

```sh
python tools/mqtt/tepy_cli.py --host 192.168.1.10 --device aabbccddeeff status
python tools/mqtt/tepy_cli.py --host 192.168.1.10 --device aabbccddeeff wake
python tools/mqtt/tepy_cli.py --host 192.168.1.10 --device aabbccddeeff type --enter
python tools/mqtt/tepy_cli.py --host 192.168.1.10 --device aabbccddeeff key a --modifier GUI
python tools/mqtt/tepy_cli.py --host broker.example.com --tls --device aabbccddeeff unlock --wait 3 --enter
```

`type` 和 `unlock` 隐藏提示输入内容，不接受命令行密码参数，不输出文本。unlock 在读取输入后发 wake，等待指定秒数，再发送输入；不检查图形桌面是否解锁，不自动重试。回车必须显式 `--enter`。

TLS 默认端口 8883；`--ca path/to/ca.pem` 使用自定义 CA 并启用 TLS，不提供跳过证书校验的选项。单条文本最长 512 字符，响应等待时限考虑固件允许的最慢输入速度。

命令只发一次（QoS 1 本身可能重传同一请求 ID），不使用 retained。客户端断开不等于取消已经交给设备的动作；设备与 Broker 断开或 BLE 中断时固件才会中止。不要在收到不确定结果后自动重复密码。
