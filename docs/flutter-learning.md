# 用 Tepy 学习 Flutter / Dart

建议先运行应用，再按“数据 → 连接 → 状态 → 页面”的顺序阅读。项目自有代码包含中文注释，尤其标出了生命周期、异步取消和密码字段的边界。

## 数据流与阅读顺序

| 层 | 建议首先阅读 | 解决的问题 |
| --- | --- | --- |
| domain | `lib/domain/connection_profile.dart`、`snapshots.dart` | 数据是什么，怎样才合法，什么时候失效 |
| data | `lib/data/mqtt_transport.dart`、`connection_store.dart` | 从哪里收发数据，怎样保存连接 |
| application | `lib/application/session_state.dart`、`providers.dart`、`session_controller.dart` | 多步操作与异步取消 |
| presentation | `lib/presentation/screens/dashboard_screen.dart` | 状态变成界面，点击变成方法调用 |
| app | `lib/main.dart`、`lib/app/tepy_app.dart` | 启动、主题、导航和前后台管理 |

以上路径相对于 `apps/mobile-flutter`。一次唤醒的数据流：按钮 → `SessionController.wake()` → 校验快照 → 编码命令 → `BrokerTransport.publish()` → ESP32 回复 → 创建新 `SessionState` → Riverpod 通知页面重建。页面不拼 MQTT JSON，网络回调不直接修改按钮。

USB 的流程：页面 → `UsbController` → `SerialManagement` → `NativeUsbTransport` → Kotlin / C++ `UsbBridge` → 原生串口。只有最底层依赖 Android / Windows API；分帧、鉴权和配置规则可以在电脑上运行 Dart 测试。

## Dart 语法在项目里的用法

1. **`final` 与 `const`**：final 字段只能赋值一次；const 还要求编译期常量。状态用 final 字段，更新时创建新对象，便于追踪变化。
2. **命名参数**：`ConnectionProfile(broker: ..., deviceId: ...)` 不依赖参数顺序；required 表示必须填写，默认值适合可选设置。
3. **空安全**：`MacSnapshot?` 表示尚未收到快照；`?.` 仅在非空时访问；`??` 提供缺省值。使用 `!` 前应先验证字段，不能只为消除编译提示。
4. **动态 JSON**：jsonDecode 的结果来自外部，不能直接视为可信模型。`object` 及各模型的 parse 方法逐个检查版本、类型、身份与时间。
5. **sealed class 与模式匹配**：BrokerEvent、UsbEvent 列出有限事件；switch 按事件类型处理，`:final topic` 等模式从对象提取字段。
6. **abstract interface class**：BrokerTransport、ConnectionStore 定义能力；正式实现访问网络/安全存储，测试用 Fake 替换。业务层不需要知道实现细节。
7. **Future、Stream、async/await**：Future 是稍后完成的一次结果，Stream 是连续事件。await 让出事件循环，不阻塞 UI；订阅在资源释放时取消。

`final Map` 只固定引用，Map 内容仍可修改。公开状态避免暴露可修改集合；敏感发送缓冲用自己持有的 Uint8List，发送后清零。Dart String、输入法和框架可能保留副本，代码不承诺所有密码内存都能擦除。

## Flutter 页面与表单

build 是“根据当前状态描述界面”，应快速且无副作用。网络连接、写存储和输入框初始化不放在 build 中重复执行。

- StatelessWidget 适合只依赖参数的卡片；ConsumerWidget 可读取 Riverpod。
- ConsumerStatefulWidget 适合持有 TextEditingController、草稿、展开状态及生命周期观察器。
- initState 初始化长期资源；dispose 清理控制器、监听。await 后使用 State / context 前检查 mounted。
- setState 用于导航索引等本页状态；跨页设备状态由 Riverpod 管理。
- TextEditingController 在 State 中持有，不在每次 build 时创建，否则刷新会覆盖草稿、移动光标。
- Wrap、滚动视图与卡片支持窄屏；widget_test 专门检查 320 像素宽度。

首页用 IndexedStack 保留各页表单与滚动位置。登录输入放在独立对话框，关闭或进入后台清理；不把内容放入 Provider，普通状态快照不会收到它。USB 页面不轮询配置，避免忙碌状态周期性打断编辑。

0.1.2 的 TLS 灰框修复展示了 ValueKey 与 PageStorageKey 的区别：普通 Key 帮助 Flutter 匹配元素，不会为 PageStorage 建立独立存储路径。ExpansionTile 保存 bool，输入框内部的 Scrollable 保存 double；两者如果只继承同一个列表的 PageStorageKey，就可能互相读到错误类型。现在展开控件有自己的 PageStorageKey，每个输入框外层 Padding 也有独立 PageStorageKey，TextField 保留原 Key 用于定位测试。这里保存的是界面展开／滚动状态，不是把输入内容写到磁盘。

0.1.3 的圆角点击反馈说明 shape 与 clipBehavior 的分工：shape 定义外观，子级 Material 上绘制的水波纹还要在边界裁剪。TLS 卡片与内部 ExpansionTile 使用相同圆角，并显式启用 Clip.antiAlias。测试按住手势并推进动画帧，分别查看折叠、展开时的高亮，避免只看点击结束后的静态界面。

快捷连接则在 SessionState 中分别保留 profile（本次连接）和 savedProfile（成功保存的档案）。load / save / forget 更新后者，普通临时连接只更新前者。状态页根据 savedProfile 决定是否显示入口，再调用 connectSaved；不需要另存一份凭据，也不让页面自行读取安全存储。

## Riverpod 3，不使用代码生成

从 providers.dart 开始：Provider 注册依赖；`NotifierProvider<SessionController, SessionState>` 公开状态和操作方法；最外层 ProviderScope 提供容器。

```dart
// watch：界面依赖状态，状态更新时重新 build。
final state = ref.watch(sessionProvider);
// read：点击时拿控制器，不订阅它。
final controller = ref.read(sessionProvider.notifier);
// select：只订阅需要的部分，减少无关重建。
final notice = ref.watch(sessionProvider.select((s) => (s.message, s.isError)));
```

ref.listen 处理变化带来的局部反应，例如 USB 回读后填表。ref.onDispose 清理定时器、订阅和连接；不能依赖某个页面刚好返回才释放资源。

`state.copyWith(...)` 返回新状态，不改原对象。session_state 集中计算 canAct 等条件，避免每个按钮各写一套就绪规则。测试的 ProviderContainer overrides 把网络替换为 FakeBroker，把时间替换为 TestClock，这就是依赖注入，无需额外单例。

## 异步取消与状态新鲜度

await 不意味着旧工作消失。例如连接 A 等待回复时，用户关闭 A 并连接 B；A 的迟到回复仍可能到达。控制器给连接与流程记录递增 epoch，每次 await 后核对它仍是当前流程；USB 原生桥另有 lease，阻止旧串口事件污染新端口。

0.1.1 的实际修复可以作为异步时序练习：`await transport.connect()` 返回和 Stream 的 BrokerConnected 投递不保证先后顺序。Future 先返回时，finally 可能安排重试；如果成功通知没有取消它，一秒后就会重新连接，清空刚收到的状态并中断解锁。现在成功通知取消旧定时器，重试入口再次检查 online。FakeBroker 的 `connectedAfterReturn` 专门模拟这种顺序；真实 MQTT 与界面测试再检查连接、状态卡和按钮持续稳定。不要为了让测试通过而把所有事件都改成同步投递。

- 网络退避只恢复订阅，不重发键盘命令。
- PUBACK 代表 Broker 接收，ESP32 sent 表示 HID 发送，Mac unlocked 是独立反馈。
- 解锁要求唤醒回执后采样的新 Mac 状态；旧 retained 锁定快照不足以允许输入。
- 取消结束后续步骤，无法撤回已交给硬件的动作；超时显示未确认，不自动重试密码。
- 墙上时间检查协议过期，Stopwatch 单调时间限制本地缓存和等待，避免系统时间调整延长寿命。

这些是业务规则，并非 Riverpod 自动提供。建议结合 session_test 的 FakeAsync 场景阅读控制器，一次只追踪一个请求 ID。

## Android 平台通道

MethodChannel `tepy/usb` 提供 list / open / write / close；EventChannel `tepy/usb/events` 传递字节块和断线。Dart 与 Kotlin 的通道名、字段名、数字类型必须一致。

Android USB 授权允许应用打开设备，ESP32 管理口令允许操作固件，这是两层验证。USB 驱动处理 CDC/ACM，Kotlin 工作线程处理 I/O；Dart 处理拆包、粘包、超时、请求 ID 与密码策略。手机没有 Windows COM7，插拔后端口 ID 可能改变。

只想先学 Flutter 时可跳过 Kotlin，先理解 UsbTransport、FakeUsb 与页面测试，再读原生桥。

## 运行测试与练习

```powershell
cd apps/mobile-flutter
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
flutter test test/session_test.dart
```

protocol_test 检查领域边界；session_test 用 FakeAsync 快进等待，检查断线、取消、不重复密码；serial_test 检查字节分帧；usb_controller_test 检查鉴权、保存回读与取消；mqtt_transport_test 用真实 MQTT 客户端与本机测试端点核对线上的协议字节；widget_test 检查表单、草稿、密码清理与窄屏；integration_test 才调用手机原生安全存储、USB 枚举和可选只读 Broker。普通 flutter test 不启动手机测试。

建议练习：先给状态页增加“固件版本”，再增加 MQTT 密码的显示/隐藏开关，最后给 USB 状态增加一个只读字段。先找现有模型，再沿既有分层修改，避免在 Widget 中直接订阅原始 MQTT。

官方参考：[Dart 语言](https://dart.dev/language)、[Flutter 布局](https://docs.flutter.dev/ui/layout)、[Riverpod](https://riverpod.dev/docs/introduction/getting_started)、[平台通道](https://docs.flutter.dev/platform-integration/platform-channels)。

## 自适应界面与 Windows（0.2.0）

`AppTheme.light()` 把字体、颜色、输入框、卡片和按钮集中管理。`TepySans` 是应用资源，不依赖手机的个性字体，也不在运行时下载。新增页面优先使用 `PageHeading` / `SectionCard`，以获得一致间距。

`LayoutBuilder` 提供父级实际约束，比只判断 Platform.isWindows 更适合布局：大于等于 1000 像素使用侧栏，窗口变小时切换底栏。`ResponsiveColumns` 决定并排或纵向，`PageContent` 通过 maxWidth 限制表单宽度。不要把窄屏的 Column 直接拉伸到整个桌面，也不要为中文内容强行固定卡片高度。

`platform_info.dart` 的 Provider 只负责有平台语义的默认值与说明，如 Windows 同机 Broker 和 Android OTG 指引；测试通过 override 模拟平台。业务模型不直接 import dart:io。

Windows `usb_bridge.cpp` 实现同样的 MethodChannel / EventChannel。SetupAPI 枚举 VID 0x303A 串口，Win32 重叠 I/O 在工作线程读写，窗口消息把回执送回 Flutter 平台线程。关闭事件取消 I/O，lease 忽略旧连接字节，写队列有长度上限。Dart 的分帧、逐请求鉴权、配置校验、超时不重发等规则无需再实现一遍。

先读 Dart 接口，再读原生桥；`windows_smoke_test.dart` 使用随机存储条目和无效测试口令验证原生通信，不读取用户口令或修改设备配置。
