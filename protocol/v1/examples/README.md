# v1 样例

所有密码均为示例占位符。发送前必须从最新状态替换 session，并使用当前时间生成 expires_at；样例中的时间不可直接使用。`config.json` 是 PATCH 请求，`config-read.json` 是脱敏响应。

`serial-request.json` / `serial-reply.json` 是 USB 管理的 JSON 正文。实际在线路上加 `@tepy:` 前缀和 LF 换行；示例 token 不是任何设备的真实口令。串口管理不使用 MQTT 的 session / expires_at，不提供键盘动作。
