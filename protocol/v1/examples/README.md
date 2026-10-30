# v1 样例

所有密码均为示例占位符。发送前必须从最新状态替换 session，并使用当前时间生成 expires_at；样例中的时间不可直接使用。`config.json` 是 PATCH 请求，`config-read.json` 是脱敏响应。

`serial-request.json` / `serial-reply.json` 是 USB 管理的 JSON 正文。实际在线路上加 `@tepy:` 前缀和 LF 换行；示例 token 不是任何设备的真实口令。串口管理不使用 MQTT 的 session / expires_at，不提供键盘动作。

`agent-state.json` 是 Mac Go 服务状态，遵循 `agent-state.schema.json`；与 ESP32 的 `state.json` 使用不同结构和 MQTT 主题。示例时间仅用于结构校验，不能作为当前在线状态。实际使用时须检查 `valid_until`，未知的锁定／HID 状态不能当作成功结果。
