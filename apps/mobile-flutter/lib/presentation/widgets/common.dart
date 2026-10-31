import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../application/session_state.dart';
import '../../app/tepy_app.dart';

/// 小组件封装统一的间距和卡片，避免每页复制一大段样式。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
            ),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

class SessionNotice extends ConsumerWidget {
  const SessionNotice({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // select 只在这两个字段改变时刷新提示；每秒状态时钟不会重复重建它。
    final data = ref.watch(
      sessionProvider.select((s) => (s.message, s.isError)),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: data.$2 ? const Color(0xFFFFF0F2) : const Color(0xFFE8F6F2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            data.$2 ? Icons.info_outline : Icons.verified_outlined,
            size: 19,
            color: data.$2 ? Colors.red.shade700 : brand,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              data.$1,
              style: TextStyle(
                fontSize: 13,
                color: data.$2 ? Colors.red.shade800 : const Color(0xFF166C5E),
              ),
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
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(color: Colors.blueGrey, fontSize: 13),
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: ink,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}
