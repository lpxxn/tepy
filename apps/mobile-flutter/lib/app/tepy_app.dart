import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers.dart';
import '../application/session_state.dart';
import '../application/usb_controller.dart';
import '../presentation/screens/connection_screen.dart';
import '../presentation/screens/controls_screen.dart';
import '../presentation/screens/dashboard_screen.dart';
import '../presentation/screens/usb_screen.dart';
import '../presentation/widgets/common.dart';
import 'app_theme.dart';
export 'app_theme.dart' show brand, ink, muted, line, canvas, success;

class TepyApp extends StatelessWidget {
  const TepyApp({super.key, this.fontFamily});
  final String? fontFamily;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tepy',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(fontFamily: fontFamily),
    home: const _Home(),
  );
}

class _Home extends ConsumerStatefulWidget {
  const _Home();
  @override
  ConsumerState<_Home> createState() => _HomeState();
}

class _HomeState extends ConsumerState<_Home> with WidgetsBindingObserver {
  int _index = 0;
  // 跨导航断点移动页面时保留同一子树，缩放窗口不丢表单草稿。
  final _pagesKey = GlobalKey(debugLabel: 'responsive-pages');
  static const _labels = ['状态', '操作', '设备', '连接'];
  static const _titles = ['设备概览', '键盘控制', '设备管理', '连接设置'];
  static const _icons = [
    Icons.dashboard_outlined,
    Icons.keyboard_alt_outlined,
    Icons.usb_rounded,
    Icons.tune_rounded,
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  void _select(int index) => setState(() => _index = index);
  Widget _pages() => IndexedStack(
    key: _pagesKey,
    index: _index,
    children: [
      DashboardScreen(
        onConnect: () => _select(3),
        onControls: () => _select(1),
      ),
      ControlsScreen(onConnect: () => _select(3)),
      const UsbScreen(),
      const ConnectionScreen(),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final linkState = ref.watch(sessionProvider.select((s) => s.link));
    // 屏幕宽度决定导航结构，不依赖操作系统。缩小 Windows 窗口同样能使用紧凑布局。
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 1000;
        return Scaffold(
          appBar: desktop
              ? null
              : AppBar(
                  title: const _Brand(),
                  actions: [
                    Padding(
                      padding: const EdgeInsets.only(right: 20),
                      child: StatusBadge(
                        linkLabel(linkState),
                        active: linkState == LinkState.online,
                      ),
                    ),
                  ],
                ),
          body: desktop
              ? Row(
                  children: [
                    _sidebar(linkState),
                    Expanded(
                      child: Column(
                        children: [
                          Container(
                            height: 80,
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              border: Border(bottom: BorderSide(color: line)),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  '工作空间',
                                  style: const TextStyle(
                                    color: muted,
                                    fontSize: 12,
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 12),
                                  child: Icon(
                                    Icons.chevron_right_rounded,
                                    size: 17,
                                    color: muted,
                                  ),
                                ),
                                Text(
                                  _titles[_index],
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                StatusBadge(
                                  linkLabel(linkState),
                                  active: linkState == LinkState.online,
                                ),
                              ],
                            ),
                          ),
                          Expanded(child: _pages()),
                        ],
                      ),
                    ),
                  ],
                )
              : SafeArea(top: false, bottom: false, child: _pages()),
          bottomNavigationBar: desktop
              ? null
              : SafeArea(
                  top: false,
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: line),
                      boxShadow: [
                        BoxShadow(
                          color: ink.withValues(alpha: 0.04),
                          blurRadius: 24,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: NavigationBar(
                        selectedIndex: _index,
                        onDestinationSelected: _select,
                        destinations: [
                          for (var i = 0; i < 4; i++)
                            NavigationDestination(
                              icon: Icon(_icons[i]),
                              label: _labels[i],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }

  Widget _sidebar(LinkState state) => Container(
    width: 224,
    color: const Color(0xFF152039),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 30, 18, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 10),
              child: _Brand(dark: true),
            ),
            const SizedBox(height: 42),
            const Padding(
              padding: EdgeInsets.only(left: 14, bottom: 14),
              child: Text(
                '工作空间',
                style: TextStyle(
                  color: Color(0xFF7887A5),
                  fontSize: 10,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: i == _index
                      ? const Color(0xFF293858)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _select(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 15,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _icons[i],
                            size: 20,
                            color: i == _index
                                ? const Color(0xFFA8B3FF)
                                : const Color(0xFF8392B0),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _labels[i],
                            style: TextStyle(
                              fontSize: 13,
                              color: i == _index
                                  ? Colors.white
                                  : const Color(0xFFADB8CF),
                              fontWeight: i == _index
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TEPY CONNECT',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.7,
                      color: Color(0xFF8D9FC4),
                    ),
                  ),
                  const SizedBox(height: 10),
                  StatusBadge(
                    linkLabel(state),
                    active: state == LinkState.online,
                    dark: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Text(
                'Tepy  0.2.0',
                style: TextStyle(fontSize: 10, color: Color(0xFF7584A2)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Brand extends StatelessWidget {
  const _Brand({this.dark = false});
  final bool dark;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: brand,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Text(
            'T',
            style: TextStyle(
              fontFamily: 'TepySans',
              color: Colors.white,
              fontSize: 23,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      const SizedBox(width: 11),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tepy',
            style: TextStyle(
              fontSize: 22,
              color: dark ? Colors.white : ink,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.7,
            ),
          ),
          Text(
            'DEVICE CONSOLE',
            style: TextStyle(
              fontSize: 7,
              color: dark ? const Color(0xFF7E8FB3) : muted,
              letterSpacing: 1.6,
            ),
          ),
        ],
      ),
    ],
  );
}
