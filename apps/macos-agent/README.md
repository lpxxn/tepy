# Tepy macOS Agent 0.1.0

Go / CGo / CoreGraphics / IOKit 状态服务，提供 MQTT 心跳、睡眠／唤醒事件、锁定／会话反馈、Tepy HID 诊断和带 Bearer 口令的只读 HTTP 接口。Qt Desktop 0.2.0 可在“Mac 状态”页查看。

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
