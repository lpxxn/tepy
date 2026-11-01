# Tepy macOS Agent 0.2.1

Go / CGo / CoreGraphics / IOKit 状态服务，提供 MQTT 心跳、睡眠／唤醒事件、锁定／会话反馈、Tepy HID 诊断、故障诊断、最近事件和带 Bearer 口令的只读 HTTP 接口。现有 Qt / Flutter 状态与键盘流程兼容；诊断和时间线的图形界面留待下一轮接入。

Apple Silicon 原生程序的首次使用：

```sh
chmod +x ./tepy-agent
./tepy-agent init
# 编辑 ~/Library/Application Support/Tepy/agent.toml
./tepy-agent validate
./tepy-agent install
./tepy-agent status
```

TOML 中默认 Broker 为 `mqtt://192.168.50.99:1883`，支持用户名／密码、CA 与客户端证书。`http.token` 自动随机生成，不使用 Mac 登录密码。默认 HTTP 只监听 localhost；局域网或全接口监听由部署者显式设置。

安装为当前 GUI 用户 LaunchAgent，不加 sudo。服务不接受远程命令，不输入或自动重试密码。锁定字段不确定时返回 unknown；事件是状态提示，不能作为身份认证依据。

源码构建需 Go 1.24+ 和 Xcode Command Line Tools：`sh tools/build-macos.sh`。Windows 可在仓库根目录运行 `tools/dev/agent.ps1` 测试通用代码。依赖固定在 go.mod / go.sum，构建产物、真实配置和 vendor 不提交。

完整配置、目录和验收见 [Go 服务文档](../../docs/macos-agent.md)，协议位于根目录 protocol/v1。

## 0.2.0：诊断与事件时间线

```sh
./tepy-agent doctor          # 配置、证书、Mac 会话 / HID、DNS / TCP / TLS / MQTT CONNECT
./tepy-agent doctor -offline # 不主动连接网络
./tepy-agent diagnostics     # 读取后台服务的持续诊断（复用配置中的 HTTP 口令）
./tepy-agent events          # 读取最近 50 条事件
./tepy-agent events -limit 200
```

`doctor` 的单次报告输出 JSON，失败项会使退出码为 1，只有警告时为 0；不修改配置或后台服务。锁定状态只能从一次性系统快照读取，unknown 时结合后台 diagnostics 观察；doctor 不启动电源 / 锁定事件监听。独立随机 MQTT 客户端仅 CONNECT / DISCONNECT，不订阅或发布消息，认证成功不等于主题发布权限通过。

后台增加 `GET /api/v1/agent/diagnostics`、`GET /api/v1/agent/events`，共用现有 Bearer 鉴权。MQTT 增加同一代理前缀下的 `diagnostics` / `events`，QoS 1、retained；原 state / availability 保持兼容。Broker 发布权限需要包含两个新主题。事件主题是最多 200 条的内存历史快照，新连接发布当前历史，历史改变时更新；不能依据旧的 retained 历史判断 Mac 是否在线。

事件包括启动、有效锁定状态、睡眠 / 唤醒、控制台切换、HID 与 MQTT 变化、电源监听异常。心跳不产生事件，相同网络错误不重复填满历史。重启清空并更换 session；增量读取必须带 session，过旧游标返回 truncated，旧进程游标返回 409。没有磁盘历史、口令、输入或任意异常文本。

协议与分页示例见 [macOS Go 服务](../../docs/macos-agent.md) 及根目录 `protocol/v1/schemas/agent-{diagnostics,events}.schema.json`。配置仍为 version=1；本轮没有实现配置重载、远程执行或 GUI。

## 0.2.1 网卡地址

新增 `internal/network`，经原有状态上报已启用网卡的 IPv4 / IPv6 与名称，随采样更新。保留旧字段，增加可选 network；不改配置，不提供新的控制命令。Flutter 0.3.1 支持显示和复制。
