# macOS Go 状态服务

服务版本 **0.1.0**，配合 Qt Desktop **0.2.0**。目标环境为 Apple Silicon / macOS 27；以当前登录用户的 LaunchAgent 运行。首版提供 MQTT 状态、睡眠／唤醒观察、用户会话和 Tepy HID 诊断，不接收远程执行、密码输入或解锁命令。

## 当前部署与连接

已在用户授权的 Mac 安装。Mac 当前地址为 `192.168.50.2`，MQTT Broker 为 `mqtt://192.168.50.99:1883`。本次按用户明确授权，将 HTTP 状态接口绑定为 `0.0.0.0:18765`；源码初始配置仍默认 `127.0.0.1:18765`。

实际配置在 Mac：

```text
~/Library/Application Support/Tepy/agent.toml
```

本次生成的同一份配置也保留在仓库的 `apps/macos-agent/agent.local.toml`，供本机查看 `http.token` 并填写 Qt。该文件被 Git 忽略，不放入任何分发包。后续若在 Mac 修改配置，需自行同步本地副本。

Qt 左侧选择“Mac 状态”，填写 `http://192.168.50.2:18765` 和 TOML 中的 `http.token`。这个口令独立于 ESP32 管理口令。页面每五秒只读刷新，展示服务在线状态、锁定状态、HID 注册、MQTT 连接及电源事件，不禁用编辑器来执行轮询。

Mac IP 改变时，监听所有网卡的已部署服务仍能接受新地址上的连接；Qt 中使用新的 Mac IP。能正确解析 Mac 的 `.local` 名称时，也可使用该名称。不要把旧地址访问失败当作 Mac 睡眠或已锁定。

## 安装与命令

分发包包含在目标 Mac 原生编译的 `tepy-agent`（darwin/arm64），运行不需要安装 Go。源码构建需要 Go 1.24+、Xcode Command Line Tools 和 CGo。本次构建使用 Go 1.27.3。

首次手工安装：

```sh
chmod +x ./tepy-agent
./tepy-agent init
# 编辑 ~/Library/Application Support/Tepy/agent.toml
./tepy-agent validate
./tepy-agent install
# 等待服务启动后查看状态
./tepy-agent status
```

`init` 只创建不存在的文件，生成随机 agent_id 和 64 位十六进制 HTTP 口令，不覆盖已有配置，不把口令打印到日志。配置权限为 0600。其他配置文件可以通过 `-config /绝对路径/agent.toml` 指定。

| 命令 | 行为 |
| --- | --- |
| init | 生成 TOML 配置与随机 HTTP 口令 |
| validate | 检查配置、CA 和客户端证书／私钥文件 |
| probe | 一次性读取原生会话／HID，不建立后台监听或 MQTT 连接 |
| run | 前台运行服务，便于开发 |
| status | 使用配置中的口令读取正在运行的服务，不输出配置秘密 |
| install | 安装／更新当前 GUI 用户的 LaunchAgent 并启动 |
| uninstall | 停止并移除 LaunchAgent，保留配置、程序及日志 |
| version | 打印版本 |

请使用已登录的普通 Mac 用户执行 install，不加 sudo。LaunchAgent 在该用户登录图形桌面后自动启动；不提供 FileVault 启动前解锁。更新服务时重复 install，已有配置保留。

安装位置：

```text
~/Library/Application Support/Tepy/bin/tepy-agent
~/Library/Application Support/Tepy/agent.toml
~/Library/LaunchAgents/com.tepy.macos-agent.plist
~/Library/Logs/Tepy/agent.log
```

日志只记录启动或错误摘要，没有周期性完整配置、HTTP 口令、MQTT 密码或 Mac 登录密码。`probe` 只做快照，锁定字段缺失时可能为 unknown；`status` 和 Qt 则读取持续运行的服务，能包含已经观察到的解锁事件。

## TOML 配置

完整样例为 `apps/macos-agent/config.example.toml`。建议使用 init 生成真实配置，再编辑业务项，不把示例口令用于部署。

```toml
version = 1
agent_id = "mac-example"
name = "Tepy Mac"
sample_seconds = 2
heartbeat_seconds = 10

[hid]
device_id = "" # 空时匹配全部 Tepy 键盘，也可填写 ESP32 完整 device_id

[http]
listen = "127.0.0.1:18765"
token = "ReplaceWithAtLeast32RandomCharacters"

[mqtt]
url = "mqtt://192.168.50.99:1883"
username = ""
password = ""
ca_file = ""
client_cert_file = ""
client_key_file = ""
```

`sample_seconds` 范围 1–30；`heartbeat_seconds` 范围 2–60，且不小于采样间隔。拒绝未知字段和不支持的版本。文件上限 64 KiB。HTTP token 为 32–128 个无空格 ASCII 字符。

HTTP 默认仅本机；跨电脑查看可明确设置 Mac 的局域网 IP。`0.0.0.0:18765` 表示监听所有 IPv4 接口，需由部署者明确选择。本次用户已授权该设置。HTTP 是受信局域网中的只读管理通道，未启用传输加密；远程观测可使用经 TLS 保护的 MQTT。

MQTT URL 支持 `mqtt://` 和 `mqtts://`，缺省端口分别为 1883 / 8883，禁止 URL 内嵌凭据。URL 留空可停用 MQTT，HTTP 和本机采样仍运行。用户名／密码可以单独使用，也可以与 TLS 客户端证书同时使用。

TLS 示例：

```toml
[mqtt]
url = "mqtts://broker.example.com:8883"
username = "example-user"
password = "example-password"
ca_file = "certs/ca.pem"
client_cert_file = "certs/client.pem"
client_key_file = "certs/client.key"
```

证书路径相对于 TOML 所在目录，也接受绝对路径。CA 留空使用系统信任库；客户端证书和私钥须成对配置。启用证书时必须使用 mqtts://，不会在明文 URL 下静默忽略证书。TLS 至少 1.2，保留服务端证书和主机名校验，没有跳过校验的开关。修改配置后重新 install 使其生效。

## 状态含义与边界

- 服务在线：说明采样／通信正在运行，不代表显示器已经点亮或密码框已准备好。
- `lock_state` 为 locked / unlocked / unknown。锁定状态取自可用的会话快照，或当前 GUI 用户收到的锁定／解锁通知；字段缺失且尚未收到事件时返回 unknown，不把缺失解释为解锁。切换离开当前控制台会清除旧事件。
- `lock_source` 标明 cg_session_property、io_console_property、screen_notification 或 unavailable。锁定字段和屏幕通知名称不是稳定的认证接口，结果用于观察与协作，不作为安全身份认证依据。
- `hid.state` 为 registered / absent / unknown。按 VID 0x303a、PID 0x4001 和键盘 Usage 匹配；只解析 hidutil 的 Devices 部分，避免 Services 重复计数。命令失败或格式不支持时返回 unknown。
- 电源监听注册 IOKit 睡眠／唤醒事件，立即确认系统通知，不阻止睡眠。Mac 休眠期间服务也暂停；将要睡眠的 MQTT 消息只能尽力发送，不能保证在断网前抵达。
- 状态带 observed_at 和 valid_until，租约为心跳间隔的三倍。客户端过期后显示未知，不能仅依据 retained 或 availability=online 判断实时状态。唤醒计数只计当前进程生命周期内观察到的事件。

实现主要依赖 [Apple 会话信息 API](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary())、[IOKit 电源通知](https://developer.apple.com/documentation/iokit/iopmlib_h) 和 [Core Foundation 分布式通知](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdistributedcenter())。屏幕通知的兼容性以目标 Mac 实测为准。

## 协议

完整字段与样例放在 `protocol/v1/schemas/agent-state.schema.json` / `protocol/v1/examples/agent-state.json`，规范见 [协议文档](protocol.md)。

MQTT：`tepy/macos/<agent_id>/state` 发布完整 JSON；`availability` 发布 online / offline。两者 QoS 1、retained。使用干净会话，遗嘱为 offline；断线后指数退避重连，只发布最新有效快照，不积压旧状态。服务不订阅命令主题。

HTTP：`GET /api/v1/agent/status`，需要 `Authorization: Bearer <http.token>`，返回相同状态。无 Cookie／CORS，拒绝跨源 Origin、请求体和写方法。错误不回显口令。返回 state_stale 表示采样已过期；Qt 会等待恢复，并将当前结果标为未知。

## 目录、构建与验证

```text
apps/macos-agent/
├── cmd/tepy-agent/        # 命令行与启动组装
├── internal/
│   ├── config/           # TOML、校验、TLS、凭据初始化
│   ├── model/            # 状态与并发快照
│   ├── platform/         # macOS 原生桥接、HID 解析、其他平台 stub
│   ├── service/          # 采样、事件与状态租约
│   ├── mqtt/             # Paho MQTT 发布、遗嘱、重连
│   ├── api/              # 只读 HTTP 与 Bearer
│   └── launchd/          # 当前用户的安装与卸载
├── tools/build-macos.sh
├── config.example.toml
└── go.mod / go.sum
```

Windows 运行 `tools/dev/agent.ps1` 做 Go 测试／vet 和开发工具构建；`-Go` 可指定 go.exe。原生 Mac 程序必须在 Mac 上执行 `sh tools/build-macos.sh` 构建；禁止将不含 CGo 的交叉编译 stub 当作可运行服务，run/install 会检查原生支持。

本轮已执行 Windows Go 测试、目标 Mac 原生 race/vet、真实 Broker 心跳订阅和 Qt 到 Mac 的只读请求。用户手动锁屏／解锁后，实际观察到 locked → unlocked。完整睡眠／唤醒、TLS Broker／mTLS 实机部署、其他 macOS 版本和用户切换仍需专项验证，详见 [测试记录](testing.md)。
