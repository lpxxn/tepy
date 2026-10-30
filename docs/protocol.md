# v1 协议

共享 Schema 位于 `protocol/v1/schemas/`，样例位于 `protocol/v1/examples/`。时间均为 Unix 毫秒。

## MQTT

主题前缀：`tepy/<device_id>`。ID 使用芯片 MAC 的十六进制字符串。命令发往 `/cmd`（QoS 1、retain=false）；回复 `/reply`（QoS 1、retain=false）；状态 `/state`（retained）。Broker ACL 应限制每台设备只访问自己的三个主题。

状态包含 `v=1`、`device_id`、`session`、`online`、`time_ready`、Wi-Fi / BLE 信息及固件版本。会话在每次 MQTT 连接时更换。设备未在线或时间未就绪时不得发送动作。

固件 0.1.1 在 `ble` 中增加可选诊断字段 `pnp_id_present`、`protocol_mode`（`report` / `boot`）、`report_subscribed`、`boot_subscribed`。`ready` 只在已连接、已加密且当前协议对应的输入通知已订阅时成立。PnP 检查和通知提交都发生在设备端，不是 macOS 的 HID 注册或输入确认。

0.1.2 增加 `host_reads`（当前连接实际读取过的特征／描述符名称列表）、`tx_completed`（当前连接 BLE 栈报告成功的输入通知数）、`tx_errors`（通知提交或完成的错误事件数）。连接重置时清零；本地启动自检不计入 `host_reads`。成功计数不代表主机 HID 驱动或应用接受了输入，错误计数也不作为自动重试依据。

0.1.4 增加可选诊断字段 `ble.encrypted`、`ble.authenticated` 和 `ble.security_status`。前两项反映设备已核实的链路加密／MITM 认证状态；`security_status` 是最近一次 ENC_CHANGE 事件的 NimBLE 返回码，`-1` 表示本次连接尚未收到该事件。已绑定重连也会在延迟检查中核实实际安全状态，因此 `security_status = -1` 本身不等于认证失败。`ready` 仍同时要求连接、加密、认证和当前模式的通知订阅；不能仅凭 `bonded` 或某一状态码决定能否输入。

```json
{"v":1,"id":"unique-request-id","session":"从最新状态获取","expires_at":1790000000000,"type":"type_text","payload":{"text":"Example!","press_enter":false}}
```

`id` 为 1–64 个 ASCII 字母、数字、`-_.`；`session` 为设备发布的 32 位十六进制字符串；`expires_at` 必须大于当前时间且不超过未来 30 秒。发布端时钟需与设备同步。过期时间在接收和开始执行前均检查，已开始的动作不因时间经过而截断。单条 JSON 最长 4096 字节，文本最多 512 个 ASCII 可打印字符。

| type | payload |
| --- | --- |
| wake | `{}`；发送 Left Shift 按下、释放 |
| type_text | `text` 必填非空，`press_enter` 可选，默认 false |
| key | `key` 必填，`modifiers` 可选数组 |

key 接受单个 ASCII 字符，以及 `ENTER TAB ESC BACKSPACE DELETE SPACE LEFT RIGHT UP DOWN HOME END PAGEUP PAGEDOWN CAPSLOCK F1` 到 `F12`。修饰键为 `CTRL SHIFT ALT GUI`，其中 ALT=Option，GUI=Command。每条 key 最多一个普通键，可组合多个不同修饰键。

回复：`{"v":1,"id":"...","status":"sent|rejected|failed","error":"..."}`。不回显文本。错误包括 `invalid_command`、`unsupported_character`、`time_not_ready`、`expired`、`old_session`、`retained_command`、`duplicate`、`dedup_full`、`busy`、`ble_not_ready`、`interrupted`、`transport_error`。没有可用 id 的畸形消息仅回复空 id 的拒绝结果。

动作不自动重试；QoS 1 重传按 id 去重。不要用 MQTT retained 保存动作。设备使用干净会话，离线不订阅、不积压命令；连接建立后的旧 session 命令拒绝。执行中 MQTT 会话改变或 BLE 连接改变会中止。密码只在运行时缓冲中短暂存在，使用后覆盖；发布端与 Broker 的日志、权限也由部署者管理。

## HTTP

根页面公开，所有 `/api/v1/` 端点要求 `Authorization: Bearer <管理口令>`。页面只在当前标签页内保存口令。无 CORS；管理 POST 要求同源。HTTP 用于受信局域网和 WPA2 配置热点，口令没有额外的 HTTP 传输加密，不应映射到公网。

| 方法 / 路径 | 行为 |
| --- | --- |
| GET /api/v1/status | 当前状态；含 BLE 配对是否待输入 |
| GET /api/v1/config | 脱敏配置与密码是否已设置 |
| PATCH /api/v1/config | 合并配置并持久化，成功后需手动重启 |
| GET /api/v1/wifi/scan | 触发异步扫描；再次请求取得结果 |
| POST /api/v1/ble/pair | 开启 120 秒配对窗口，无请求体 |
| POST /api/v1/ble/passkey | `{"passkey":"123456"}` |
| POST /api/v1/ble/clear | 断开并清除绑定，无请求体 |
| POST /api/v1/reboot | 延迟重启，无请求体 |
| POST /api/v1/ota | 原始应用 `.bin`，application/octet-stream |

配置 PATCH 省略字段表示保留；密码传空字符串表示清除（管理口令不可清空）。根 `v` 必须为 1，拒绝未知字段和不支持版本。成功返回 `{"ok":true,"reboot_required":true}`；错误为 `{"error":"错误代码"}`。OTA 成功后自动延迟重启。

## USB 串口管理（固件 0.2.0 起）

ESP32-S3 原生 USB Serial/JTAG，115200 / 8N1、无流控。默认 UART 控制台及其日志仍保留；USB 管理启用条件是 `CONFIG_TEPY_SERIAL_ENABLED` 及主／次 USB Serial/JTAG 控制台。USB-to-UART 暂未实现管理协议。

每帧为 `@tepy:` + 紧凑 UTF-8 JSON + LF。接收支持 CRLF，JSON 正文最长 20000 字节，正文内的换行必须转义。超过上限的整行丢弃直到 LF；半帧五秒没有新字节即清除。接收内容不回显，缓冲在处理后清理。

```text
@tepy:{"v":1,"id":"desktop-1","method":"status.get","token":"ExampleAdminTokenOnly0000","params":{}}
@tepy:{"v":1,"id":"desktop-1","ok":true,"result":{"v":1,"device_id":"aabbccddeeff"}}
```

上方状态结果只展示结构，完整结构遵循 `state.schema.json`。请求和回复 Schema 分别为 `serial-request.schema.json` / `serial-reply.schema.json`。示例口令不是设备真实口令。

| method | params | result |
| --- | --- | --- |
| status.get | `{}` | 与 HTTP status 相同 |
| config.get | `{}` | 与 HTTP 脱敏配置相同 |
| config.patch | 配置 PATCH，含 `v:1` | `{"ok":true,"reboot_required":true}` |
| wifi.scan | `{}` | `scanning`；结束时含 `networks` |
| ble.pair | `{}` | `{"ok":true}` |
| ble.passkey | `{"passkey":"123456"}` | `{"ok":true}` |
| ble.clear | `{}` | `{"ok":true}` |
| reboot | `{}` | `{"ok":true}`，设备延迟重启 |

每次请求都必须携带当前管理口令，不能由物理连接跳过鉴权。`id` 为 1–64 个 ASCII 字母、数字、`-_.`，客户端为每次请求生成新 ID，忽略不匹配回复。没有可用 ID 的错误回复使用空 ID。

成功封装为 `{"v":1,"id":"...","ok":true,"result":{...}}`，失败为 `{"v":1,"id":"...","ok":false,"error":"..."}`。协议错误包括 `invalid_request`、`unsupported_version`、`unauthorized`、`frame_too_large`、`internal_error`；业务错误复用 HTTP，例如 `invalid_wifi_password`、`busy`、`already_bonded`、`invalid_passkey`。不回显 token、配置密码或配对码。

USB 回复和普通启动日志可能共用串口；客户端只解析以 `@tepy:` 开头的完整行，不展示其他行。Qt 只跟踪一个有效管理请求，15 秒没有对应回复即报结果未确认，不自动重发。桌面 0.1.1 允许用户操作替代后台状态／扫描读取，取消客户端等待并忽略旧 ID 的迟到回复；前台写操作不被替代，也不积压或重发。此接口不提供 MQTT 动作或串口二进制 OTA；固件升级使用 HTTP OTA 或 ROM 下载器。
