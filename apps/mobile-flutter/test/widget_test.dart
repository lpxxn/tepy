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

import 'support/fakes.dart';

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
      void Function() dispose,
    })
  >
  mount(WidgetTester tester, {double width = 390, double height = 844}) async {
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
        appPlatformProvider.overrideWithValue(AppPlatform.android),
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
    for (final title in ['操作', '设备', '连接', '状态']) {
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
      for (final tab in ['操作', '设备', '连接']) {
        await tester.tap(find.text(tab).last);
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
}
