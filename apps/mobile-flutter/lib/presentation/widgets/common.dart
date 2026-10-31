import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../application/session_state.dart';
import '../../app/app_theme.dart';

/// 同一页面使用一个有界滚动区域，桌面不会把手机表单拉伸到整个屏幕。
class PageContent extends StatelessWidget {
  const PageContent({
    super.key,
    required this.storageKey,
    required this.children,
    this.maxWidth = 1180,
  });
  final PageStorageKey<String> storageKey;
  final List<Widget> children;
  final double maxWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: math.min(constraints.maxWidth, maxWidth),
        child: ListView(
          key: storageKey,
          padding: EdgeInsets.fromLTRB(
            constraints.maxWidth >= 700 ? 28 : 20,
            20,
            constraints.maxWidth >= 700 ? 28 : 20,
            32,
          ),
          children: children,
        ),
      ),
    ),
  );
}

class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });
  final String eyebrow, title, subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
            color: brand,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          title,
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.7,
            color: ink,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 12, height: 1.6, color: muted),
        ),
      ],
    ),
  );
}

/// 桌面并排，手机纵向排列；不使用固定高度，兼容中文换行与大字体。
class ResponsiveColumns extends StatelessWidget {
  const ResponsiveColumns({
    super.key,
    required this.first,
    required this.second,
    this.breakpoint = 820,
    this.firstFlex = 1,
    this.secondFlex = 1,
  });
  final Widget first, second;
  final double breakpoint;
  final int firstFlex, secondFlex;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth >= breakpoint
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: firstFlex, child: first),
              const SizedBox(width: 20),
              Expanded(flex: secondFlex, child: second),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [first, const SizedBox(height: 16), second],
          ),
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: brand),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 12, height: 1.6, color: muted),
            ),
          ],
          const SizedBox(height: 18),
          child,
        ],
      ),
    ),
  );
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(
    this.label, {
    super.key,
    this.active = false,
    this.dark = false,
  });
  final String label;
  final bool active, dark;
  @override
  Widget build(BuildContext context) {
    final color = active ? success : (dark ? const Color(0xFFB3BED7) : muted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.08)
            : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: dark ? Colors.white : color,
            ),
          ),
        ],
      ),
    );
  }
}

class SessionNotice extends ConsumerWidget {
  const SessionNotice({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(
      sessionProvider.select((s) => (s.message, s.isError)),
    );
    final color = data.$2 ? const Color(0xFFBC465C) : const Color(0xFF66748D);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: data.$2 ? const Color(0xFFFFF0F3) : const Color(0xFFEDF1F8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            data.$2 ? Icons.info_outline_rounded : Icons.info_outline_rounded,
            size: 17,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              data.$1,
              style: TextStyle(fontSize: 12, height: 1.7, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

String linkLabel(LinkState link) => switch (link) {
  LinkState.offline => '未连接',
  LinkState.connecting => '连接中',
  LinkState.online => '已连接',
  LinkState.reconnecting => '重连中',
};

class DetailRow extends StatelessWidget {
  const DetailRow(this.title, this.value, {super.key});
  final String title, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: ink,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}
