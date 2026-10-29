# 架构与目录约定

## 数据流

MQTT → JSON 校验 → 类型化 Command → 单任务执行器 → BLE HID。HTTP 管理接口调用配置、网络、蓝牙和升级服务，不直接产生键盘动作。

## 组件职责

| 目录 | 职责 |
| --- | --- |
| firmware/main | 初始化、资源组装、按键恢复、状态快照、命令任务 |
| tepy_core | 与硬件无关的命令、字符映射、校验、去重和执行 |
| tepy_ble | NimBLE 生命周期、绑定、配对码、HID |
| tepy_config | 版本化配置、NVS、敏感字段脱敏 |
| tepy_network | STA / SoftAP、SNTP、mDNS、连接恢复 |
| tepy_mqtt | MQTT 会话、收包、发布、TLS |
| tepy_web | HTTP Bearer 管理、静态页面、API 路由 |
| tepy_ota | 镜像接收、检查、备用分区、回滚确认 |
| protocol/v1 | 所有客户端共享的 JSON Schema 和样例 |

自有组件使用 C++23，异常和 RTTI 关闭。入口有 C linkage；底层 ESP-IDF、NimBLE 保留 C 实现。使用 RAII、固定容量命令缓冲及显式错误返回。配置受互斥锁保护；网络回调只更新状态，输入在独立 FreeRTOS 任务完成。

从 0.1.2 起，HID 服务由 `tepy_ble` 内的 C++ 服务表显式注册，运行时不使用 SDK `esp_hidd` 封装。`hid_profile.hpp` 定义 HOGP 特征、权限与报告引用；`hid_profile.cpp` 提供可主机测试的字节访问器；`gatt.cpp` 把同一服务表映射到 NimBLE，记录真实主机读取并处理协议及 LED 写入。Report Map 只包含本 HID 服务的键盘报告，不发布 External Report Reference；电池服务独立提供 Battery Level。PnP 按七个二进制字节输出，不调用字符串长度函数。

从 0.1.3 起，HID 服务的所有可读值、Report Reference 描述符要求加密，所有可写值要求加密；Report 与 Boot 输入还设置 `BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC`，单独保护 NimBLE 自动生成的 CCCD 写入。只设置输入的 `READ_ENC` 不会保护其他元数据或 CCCD；macOS 可能在配对完成前枚举并订阅，随后因链路尚未加密而拒绝创建 HID 设备。DIS 设备信息仍可公开读取，配对认证方式保持不变。

Profile 访问由独立互斥锁保护；通知前先复制状态、释放锁，再调用 NimBLE，避免与主机访问回调形成锁顺序反转。主机侧 SDK 解析测试与 GATT 字节契约测试独立于无线硬件；它们不证明 macOS 已经注册键盘。

MQTT 重连生成新的随机 session；只接受当前 session。每条动作最多未来 30 秒有效，需先 SNTP 校时。去重缓存不驱逐仍有效的记录，缓存满则拒绝。OTA 与键盘执行互斥。网络断线或 BLE 中断后不会自动续发文本。

## 扩展约定

Qt 与 Go 只依赖公开协议。未来串口适配器复用配置服务和命令模型，不在 UART 回调内重新实现业务。协议主版本变化新增目录；兼容字段变化更新当前 Schema 和样例。配置版本不支持时返回错误，保留 NVS，不自动擦除。

首版只支持一个活动 Broker、一个蓝牙目标。固件运行时对象存活至重启；网页随应用原子升级。
