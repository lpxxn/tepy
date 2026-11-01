import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/app/tepy_app.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/data/platform_info.dart';
import 'package:tepy_mobile/application/usb_controller.dart';
import 'package:tepy_mobile/application/mac_password_controller.dart';
import 'package:tepy_mobile/application/firmware_controller.dart';

import 'support/fakes.dart';
import 'support/firmware_fixtures.dart';

import 'package:tepy_mobile/data/mac_password_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? font;
  setUpAll(() async {
    final sdk =
        Platform.environment['FLUTTER_ROOT'] ?? 'C:/Users/nick/develop/flutter';
    final icons = File(
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      final loader = FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(await icons.readAsBytes())));
      await loader.load();
    }
    final loader = FontLoader('TepySans')
      ..addFont(rootBundle.load('assets/fonts/TepySans.ttf'));
    await loader.load();
    font = 'TepySans';
  });

  Future<
    ({
      ProviderContainer container,
      FakeBroker broker,
      FakeStore store,
      FakeUsb usb,
      void Function() dispose,
    })
  >
  mount(
    WidgetTester tester, {
    double width = 390,
    double height = 844,
    AppPlatform platform = AppPlatform.android,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final clock = TestClock(),
        broker = FakeBroker(TestClock()),
        store = FakeStore(),
        usb = FakeUsb();
    final container = ProviderContainer(
      overrides: [
        appPlatformProvider.overrideWithValue(platform),
        macPasswordStoreProvider.overrideWithValue(FakeMacPasswords()),
        firmwareTargetStoreProvider.overrideWithValue(FakeFirmwareStore()),
        firmwarePickerProvider.overrideWithValue(FakeFirmwarePicker()),
        clockProvider.overrideWithValue(clock),
        connectionStoreProvider.overrideWithValue(store),
        transportFactoryProvider.overrideWithValue(() => broker),
        usbTransportFactoryProvider.overrideWithValue(() => usb),
        usbTokenStoreProvider.overrideWithValue(FakeUsbTokenStore()),
      ],
    );
    var disposed = false;
    void dispose() {
      if (!disposed) {
        disposed = true;
        container.dispose();
      }
    }

    addTearDown(dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: const Key('preview'),
          child: TepyApp(fontFamily: font),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (
      container: container,
      broker: broker,
      store: store,
      usb: usb,
      dispose: dispose,
    );
  }

  Future<void> preview(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('build/previews');
      await dir.create(recursive: true);
      await File('${dir.path}/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('Windows delayed USB secret reply preserves the visible input', (
    tester,
  ) async {
    final app = await mount(
      tester,
      width: 1440,
      height: 900,
      platform: AppPlatform.windows,
    );
    final replyGate = Completer<void>();
    app.usb.secretReplyGate = replyGate.future;
    await tester.tap(find.text('设备').last);
    await tester.pumpAndSettle();
    final controller = app.container.read(usbProvider.notifier);
    await controller.connect('1:0', 'ExampleAdminTokenOnly0000');
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('usbWifiPassword'));
    final scrollable = find
        .descendant(
          of: find.byKey(const PageStorageKey('usb')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(field, 250, scrollable: scrollable);
    await Scrollable.ensureVisible(tester.element(field), alignment: 0.4);
    await tester.pumpAndSettle();
    expect(app.container.read(usbProvider).connected, true);
    expect(tester.widget<TextField>(field).enabled, true);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(
      tester.widget<TextField>(field).decoration!.hintText,
      contains('已保存'),
    );
    expect(tester.widget<TextField>(field).readOnly, true);
    expect(
      tester.widget<TextField>(field).decoration!.floatingLabelBehavior,
      FloatingLabelBehavior.always,
    );
    await preview(tester, 'saved-passwords-initial');
    final toggle = find.descendant(
      of: field,
      matching: find.byType(IconButton),
    );
    final inputElement = tester.element(field);
    final inputBounds = tester.getRect(field);
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 150));
    expect(app.container.read(usbProvider).busy, true);
    expect(
      tester.element(field),
      same(inputElement),
      reason: 'Reading a secret must retain the input element',
    );
    expect(
      tester.getRect(field),
      inputBounds,
      reason: 'Reading a secret must not shift the page layout',
    );
    replyGate.complete();
    await tester.pumpAndSettle();
    expect(tester.element(field), same(inputElement));
    expect(tester.getRect(field), inputBounds);
    expect(
      tester.widget<TextField>(field).controller!.text,
      'SavedWifiOnly123',
    );
    expect(tester.widget<TextField>(field).obscureText, false);
    expect(tester.widget<TextField>(field).readOnly, true);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).obscureText, true);
    await preview(tester, 'saved-passwords');
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await tester.pump();
  });

  testWidgets(
    'four pages render, network update preserves draft, no auto-connect',
    (tester) async {
      final app = await mount(tester);
      expect(app.broker.connections, 0);
      expect(find.text('状态未知'), findsOneWidget);
      await tester.tap(find.text('连接').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('brokerField')),
        'mqtt://draft.example:1883',
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('brokerField')))
            .controller!
            .text,
        'mqtt://draft.example:1883',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('设备').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('refreshUsb')));
      await tester.pumpAndSettle();
      expect(find.textContaining('请选择设备'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.pump();
    },
  );

  testWidgets('phone controls clear input and never save typed content', (
    tester,
  ) async {
    final app = await mount(tester);
    await app.container.read(sessionProvider.notifier).connect(testProfile);
    await tester.pumpAndSettle();
    await preview(tester, 'dashboard');
    await tester.tap(find.text('操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送文字'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('actionInput')),
      'ExampleOnly!',
    );
    await tester.tap(find.byKey(const Key('confirmInput')));
    await tester.pumpAndSettle();
    expect(app.broker.sent.single['type'], 'type_text');
    expect(find.byKey(const Key('actionInput')), findsNothing);
    expect(
      app.store.saved!.toStorageJson().values,
      isNot(contains('ExampleOnly!')),
    );
    await preview(tester, 'controls');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('设备').last);
    await tester.pumpAndSettle();
    await preview(tester, 'usb');
    await tester.tap(find.text('连接').last);
    await tester.pumpAndSettle();
    await preview(tester, 'connection');
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await tester.pump();
  });

  testWidgets(
    'saved connection is reachable on dashboard with one connect in flight',
    (tester) async {
      final app = await mount(tester, width: 320);
      final controller = app.container.read(sessionProvider.notifier);
      final gate = Completer<void>();
      app.broker.connectGate = gate;
      expect(find.byKey(const Key('dashboardConnect')), findsOneWidget);
      expect(app.broker.connections, 0);
      await preview(tester, 'dashboard-saved-connection');
      await tester.tap(find.byKey(const Key('dashboardConnect')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('连接中…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('dashboardConnect')))
            .onPressed,
        isNull,
      );
      unawaited(controller.connectSaved());
      await tester.pump();
      expect(app.broker.connections, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dashboardConnect')), findsNothing);
      await controller.disconnect();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dashboardConnect')), findsOneWidget);
      await controller.forget();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dashboardConnect')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'late connection event keeps status cards and wake button stable',
    (tester) async {
      final app = await mount(tester);
      app.broker.connectedAfterReturn = true;
      await app.container.read(sessionProvider.notifier).connect(testProfile);
      await tester.pumpAndSettle();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('已锁定'), findsOneWidget);
        expect(find.text('在线'), findsOneWidget);
        expect(find.text('就绪'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('dashboardWake')))
              .onPressed,
          isNotNull,
        );
        expect(app.broker.connections, 1);
      }
      expect(app.broker.sent, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.pump();
    },
  );

  testWidgets('small phone renders all tabs without overflow', (tester) async {
    final app = await mount(tester, width: 320);
    for (final title in ['操作', 'Mac', '设备', '固件', '连接', '状态']) {
      await tester.tap(find.text(title).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await tester.pump();
  });

  testWidgets('TLS certificate section expands without layout errors', (
    tester,
  ) async {
    final app = await mount(tester, width: 360);
    await tester.tap(find.text('连接').last);
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byKey(const PageStorageKey('connection')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('TLS 证书'),
      250,
      scrollable: scrollable,
    );
    // ensureVisible 只保证有交集；再向上滚动，避免标题落在底部导航栏下面。
    await tester.drag(scrollable, const Offset(0, -250));
    await tester.pumpAndSettle();
    Future<void> reveal(Finder target) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      // 展开动画和多行输入框会改变布局；按真实手势滚动到导航栏之外。
      final bounds = tester.getRect(
        find.byKey(const PageStorageKey('connection')),
      );
      for (var i = 0; i < 12; i++) {
        final center = tester.getCenter(target).dy;
        if (center > bounds.top + 60 && center < bounds.bottom - 60) return;
        await tester.drag(
          scrollable,
          Offset(0, center >= bounds.bottom - 60 ? -220 : 220),
        );
        await tester.pumpAndSettle();
      }
      fail('目标控件无法滚动到可点击区域');
    }

    Future<void> toggleTls({String? pressedPreview}) async {
      await reveal(find.text('TLS 证书'));
      if (pressedPreview == null) {
        await tester.tap(find.text('TLS 证书'));
      } else {
        // 停在按下状态检查高亮，稳态展开截图看不到未裁剪的矩形水波纹。
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('TLS 证书')),
        );
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 100));
        await preview(tester, pressedPreview);
        await gesture.up();
      }
      await tester.pumpAndSettle();
    }

    await toggleTls(pressedPreview: 'tls-pressed-collapsed');
    expect(find.byKey(const Key('caField')), findsOneWidget);
    await preview(tester, 'tls-expanded');
    await reveal(find.byKey(const Key('caField')));
    await tester.enterText(
      find.byKey(const Key('caField')),
      'Example CA draft only',
    );
    await toggleTls(pressedPreview: 'tls-pressed-expanded');
    await toggleTls();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('caField')))
          .controller!
          .text,
      'Example CA draft only',
    );
    await reveal(find.text('填写客户端私钥'));
    await tester.tap(find.text('填写客户端私钥'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('privateKeyField')), findsOneWidget);
    await app.container.read(sessionProvider.notifier).connect(testProfile);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const Key('caField'))).enabled,
      false,
    );
    // 已连接时同样允许查看证书区域，编辑禁用不会产生布局错误。
    await toggleTls();
    await toggleTls();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await tester.pump();
  });
  testWidgets(
    'desktop navigation adapts when resizing and actions stay reachable',
    (tester) async {
      final app = await mount(tester, width: 1440, height: 1000);
      await app.container.read(sessionProvider.notifier).connect(testProfile);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('TEPY CONNECT'), findsOneWidget);
      await preview(tester, 'windows-dashboard');
      for (final tab in ['操作', 'Mac', '设备', '固件', '连接']) {
        await tester.tap(find.byKey(ValueKey('nav-$tab')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await preview(tester, 'windows-$tab');
      }
      await app.container.read(sessionProvider.notifier).disconnect();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('brokerField')),
        'mqtt://resize.example:1883',
      );
      tester.view.physicalSize = const Size(800, 700);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(1440, 1000);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('brokerField')))
            .controller!
            .text,
        'mqtt://resize.example:1883',
      );
      await app.container.read(sessionProvider.notifier).connect(testProfile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('操作').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送文字'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('actionInput')),
        'DesktopExample!',
      );
      await tester.tap(find.byKey(const Key('confirmInput')));
      await tester.pumpAndSettle();
      expect(app.broker.sent.single['type'], 'type_text');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'Mac IP refreshes, copies, wraps on small screens and clears offline',
    (tester) async {
      final app = await mount(tester);
      app.broker.heartbeat = false;
      await app.container.read(sessionProvider.notifier).connect(testProfile);
      final clock = app.container.read(clockProvider);
      Map<String, dynamic> sample(int sequence, String ip) =>
          macJson(clock, sequence: sequence)
            ..['network'] = {
              'available': true,
              'addresses': [
                {'interface': 'en0', 'ip': ip, 'family': 'ipv4'},
                {
                  'interface': 'en0',
                  'ip': '2001:db8:1234:5678:abcd:1234:5678:abcd',
                  'family': 'ipv6',
                },
              ],
            };
      app.broker.message(
        '${testProfile.agentPrefix}/state',
        sample(100, '192.168.50.90'),
      );
      await tester.pumpAndSettle();
      expect(
        app.container.read(sessionProvider).mac?.network?.addresses.first.ip,
        '192.168.50.90',
      );
      await tester.scrollUntilVisible(
        find.text('Mac IP 地址'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('dashboard')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('192.168.50.90'), findsOneWidget);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.ensureVisible(find.byTooltip('复制 IP 地址').first);
      await tester.tap(find.byTooltip('复制 IP 地址').first);
      await tester.pumpAndSettle();
      expect(copied, '192.168.50.90');
      await tester.tap(find.byKey(const ValueKey('nav-Mac')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(320, 844);
      await tester.pumpAndSettle();
      expect(find.text('192.168.50.90'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await preview(tester, 'mac-ip-phone');
      app.broker.message(
        '${testProfile.agentPrefix}/state',
        sample(101, '192.168.50.246'),
      );
      await tester.pumpAndSettle();
      expect(find.text('192.168.50.246'), findsOneWidget);
      expect(find.text('192.168.50.90'), findsNothing);
      await app.container.read(sessionProvider.notifier).disconnect();
      await tester.pumpAndSettle();
      expect(find.text('192.168.50.246'), findsNothing);
      expect(app.broker.sent, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.pump();
    },
  );
  testWidgets('Mac diagnostics and timeline render valid same-session data', (
    tester,
  ) async {
    final app = await mount(tester, width: 1440, height: 1000);
    await app.container.read(sessionProvider.notifier).connect(testProfile);
    final clock = app.container.read(clockProvider);
    app.broker.message(
      '${testProfile.agentPrefix}/diagnostics',
      diagnosticJson(clock),
    );
    app.broker.message('${testProfile.agentPrefix}/events', historyJson(clock));
    await tester.tap(find.text('Mac').last);
    await tester.pumpAndSettle();
    await preview(tester, 'mac-status');
    await tester.tap(find.text('诊断'));
    await tester.pumpAndSettle();
    expect(find.text('服务采样正常。'), findsOneWidget);
    await preview(tester, 'mac-diagnostics');
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    expect(find.text('屏幕解锁'), findsOneWidget);
    await preview(tester, 'mac-events');
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await tester.pump();
  });
  testWidgets(
    'saved password unlock dialog uses metadata without prefilling secret',
    (tester) async {
      final app = await mount(tester);
      final passwords =
          app.container.read(macPasswordStoreProvider) as FakeMacPasswords;
      passwords.values[macPasswordTarget(testProfile)] = (
        'ExampleStoredOnly!',
        const MacPasswordInfo(),
      );
      await app.container
          .read(macPasswordProvider.notifier)
          .refresh(testProfile);
      await app.container.read(sessionProvider.notifier).connect(testProfile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('操作').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('唤醒并输入解锁'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('useSavedMacPassword')), findsOneWidget);
      expect(find.byKey(const Key('actionInput')), findsNothing);
      expect(find.text('ExampleStoredOnly!'), findsNothing);
      expect(passwords.reads, 0);
      await preview(tester, 'saved-password-unlock');
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(app.broker.sent, isEmpty);
      expect(passwords.reads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'Mac password settings saves explicitly and clears current target',
    (tester) async {
      final app = await mount(tester, width: 1440, height: 1000);
      await app.container.read(sessionProvider.notifier).connect(testProfile);
      await tester.tap(find.byKey(const ValueKey('nav-操作')));
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey('controls')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('macPasswordSettings')),
        220,
        scrollable: scrollable,
      );
      await tester.ensureVisible(find.byKey(const Key('macPasswordSettings')));
      await tester.tap(find.byKey(const Key('macPasswordSettings')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('savedMacPasswordInput')),
        'ExampleSettingsOnly!',
      );
      await tester.tap(find.byKey(const Key('saveMacPassword')));
      await tester.pumpAndSettle();
      final passwords =
          app.container.read(macPasswordStoreProvider) as FakeMacPasswords;
      expect(
        passwords.values[macPasswordTarget(testProfile)]?.$1,
        'ExampleSettingsOnly!',
      );
      expect(find.text('ExampleSettingsOnly!'), findsNothing);
      await tester.ensureVisible(find.text('清除保存的密码'));
      await tester.tap(find.text('清除保存的密码'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除').last);
      await tester.pumpAndSettle();
      expect(passwords.values, isEmpty);
      expect(app.broker.sent, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.pump();
    },
  );
  testWidgets('firmware selection is reviewed before enabling an upgrade', (
    tester,
  ) async {
    final app = await mount(tester, width: 1440, height: 1000);
    (app.container.read(firmwarePickerProvider) as FakeFirmwarePicker).image =
        testFirmware();
    await tester.tap(find.byKey(const ValueKey('nav-固件')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('otaPickImage')));
    await tester.pumpAndSettle();
    expect(find.text('tepy.bin'), findsOneWidget);
    expect(find.text('9.9.9'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('otaUpgrade')))
          .onPressed,
      isNull,
    );
    await preview(tester, 'firmware');
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await tester.pump();
  });
  testWidgets(
    'USB firmware UI uses existing connection and reviews before writing',
    (tester) async {
      final app = await mount(tester, width: 390, height: 844);
      app.usb.statusOverride = {
        'v': 1,
        'device_id': 'aabbccddeeff',
        'firmware': '0.3.0',
        'session': '',
        'boot_session': 'd' * 32,
        'busy': false,
        'usb_ota': {'v': 1, 'max_chunk_bytes': 3072},
      };
      await app.container
          .read(usbProvider.notifier)
          .connect('1:0', 'ExampleAdminTokenOnly0000');
      (app.container.read(firmwarePickerProvider) as FakeFirmwarePicker).image =
          testFirmware();
      await tester.tap(find.byKey(const ValueKey('nav-固件')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USB 升级'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('otaDevice')),
        'aabbccddeeff',
      );
      await tester.ensureVisible(find.byKey(const Key('usbOtaReadStatus')));
      await tester.tap(find.byKey(const Key('usbOtaReadStatus')));
      await tester.pumpAndSettle();
      expect(app.container.read(firmwareProvider).device?['firmware'], '0.3.0');
      final scroll = find
          .descendant(
            of: find.byKey(const PageStorageKey('firmware')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('otaPickImage')),
        200,
        scrollable: scroll,
      );
      await tester.tap(find.byKey(const Key('otaPickImage')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('otaUpgrade')),
        200,
        scrollable: scroll,
      );
      await tester.ensureVisible(find.byKey(const Key('otaUpgrade')));
      await tester.drag(scroll, const Offset(0, -220));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('otaUpgrade')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('otaUpgrade')));
      await tester.pumpAndSettle();
      expect(find.textContaining('方式：USB 数据线'), findsOneWidget);
      await preview(tester, 'usb-firmware-confirm');
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(
        app.usb.sent.any((f) => (f['method'] as String).startsWith('ota.')),
        false,
      );
      tester.view.physicalSize = const Size(320, 844);
      await tester.pumpAndSettle();
      await tester.drag(scroll, const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await preview(tester, 'usb-firmware-phone');
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.pump();
    },
  );
}
