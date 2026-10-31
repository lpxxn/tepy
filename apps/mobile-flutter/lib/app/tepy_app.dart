import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../application/usb_controller.dart';
import '../presentation/screens/connection_screen.dart';
import '../presentation/screens/controls_screen.dart';
import '../presentation/screens/dashboard_screen.dart';
import '../presentation/screens/usb_screen.dart';

const brand = Color(0xFF0D9488);
const ink = Color(0xFF13283E);

class TepyApp extends StatelessWidget {
  const TepyApp({super.key, this.fontFamily});

  /// 测试可注入本机中文字体；APK 使用安卓系统字体，不下载网络字体。
  final String? fontFamily;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tepy',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: brand,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFF4F7FB),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF4F7FB),
        foregroundColor: ink,
        centerTitle: false,
      ),
      cardTheme: const CardThemeData(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(22)),
          side: BorderSide(color: Color(0xFFE3EAF1)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF7F9FC),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFDCE5EE)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFDCE5EE)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xFFD7F3ED),
      ),
    ),
    home: const _Home(),
  );
}

/// ConsumerStatefulWidget 同时具备本地界面状态和 Riverpod 的 ref。
/// “选中了哪个页面”只影响本 Widget，所以用 setState；网络和任务放在 Notifier。
class _Home extends ConsumerStatefulWidget {
  const _Home();
  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 首帧之后读取存储，不在 build 过程中同步修改被 Widget 监听的状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(sessionProvider.notifier).initialize());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(
        ref.read(sessionProvider.notifier).disconnect(background: true),
      );
      unawaited(ref.read(usbProvider.notifier).disconnect());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [
          CircleAvatar(
            backgroundColor: brand,
            foregroundColor: Colors.white,
            child: Text('T', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
          SizedBox(width: 12),
          Text('Tepy', style: TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
      actions: const [
        Padding(
          padding: EdgeInsets.only(right: 20),
          child: Text(
            '移动控制台',
            style: TextStyle(fontSize: 12, color: Colors.blueGrey),
          ),
        ),
      ],
    ),
    // IndexedStack 保留各页面的本地表单和滚动位置，切页不重新创建 TextEditingController。
    body: SafeArea(
      child: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(onConnect: () => setState(() => _index = 3)),
          ControlsScreen(onConnect: () => setState(() => _index = 3)),
          const UsbScreen(),
          const ConnectionScreen(),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: (index) => setState(() => _index = index),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.space_dashboard_outlined),
          selectedIcon: Icon(Icons.space_dashboard),
          label: '状态',
        ),
        NavigationDestination(
          icon: Icon(Icons.keyboard_alt_outlined),
          selectedIcon: Icon(Icons.keyboard_alt),
          label: '操作',
        ),
        NavigationDestination(
          icon: Icon(Icons.usb_outlined),
          selectedIcon: Icon(Icons.usb),
          label: '设备',
        ),
        NavigationDestination(
          icon: Icon(Icons.tune_outlined),
          selectedIcon: Icon(Icons.tune),
          label: '连接',
        ),
      ],
    ),
  );
}
