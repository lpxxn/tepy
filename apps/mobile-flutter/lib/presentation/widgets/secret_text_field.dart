import 'package:flutter/material.dart';

/// 显示状态仅属于当前输入框，清空或禁用后恢复隐藏。
class SecretTextField extends StatefulWidget {
  const SecretTextField({
    super.key,
    this.inputKey,
    required this.controller,
    required this.decoration,
    this.enabled = true,
    this.readOnly = false,
    this.saved = false,
    this.onReveal,
    this.maxLength,
    this.keyboardType = TextInputType.visiblePassword,
    this.onChanged,
  });

  final Key? inputKey;
  final TextEditingController controller;
  final InputDecoration decoration;
  final bool enabled;
  final bool readOnly, saved;
  final Future<String> Function()? onReveal;
  final int? maxLength;
  final TextInputType keyboardType;
  final ValueChanged<String>? onChanged;

  @override
  State<SecretTextField> createState() => _SecretTextFieldState();
}

class _SecretTextFieldState extends State<SecretTextField> {
  bool _visible = false;
  bool _loading = false;
  String? _error;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_resetIfEmpty);
  }

  void _resetIfEmpty() {
    if (widget.controller.text.isEmpty) _revision++;
    if (_visible && widget.controller.text.isEmpty) {
      setState(() => _visible = false);
    }
  }

  @override
  void didUpdateWidget(covariant SecretTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_resetIfEmpty);
      widget.controller.addListener(_resetIfEmpty);
      _visible = false;
      _revision++;
    }
    if (oldWidget.readOnly != widget.readOnly ||
        oldWidget.saved != widget.saved) {
      _visible = false;
      _revision++;
    }
    if (!widget.enabled) _visible = false;
  }

  Future<void> _toggle() async {
    if (_visible) {
      setState(() => _visible = false);
      return;
    }
    final controller = widget.controller, revision = _revision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.saved && controller.text.isEmpty && widget.onReveal != null) {
        final value = await widget.onReveal!();
        if (!mounted || revision != _revision) return;
        controller.text = value;
      }
      if (mounted && revision == _revision) setState(() => _visible = true);
    } catch (_) {
      if (mounted && revision == _revision) {
        setState(() => _error = '无法读取已保存口令，请确认设备固件支持此功能。');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_resetIfEmpty);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: widget.inputKey,
    controller: widget.controller,
    enabled: widget.enabled,
    readOnly: widget.readOnly,
    obscureText: !_visible,
    maxLength: widget.maxLength,
    keyboardType: widget.keyboardType,
    autocorrect: false,
    enableSuggestions: false,
    enableIMEPersonalizedLearning: false,
    onChanged: widget.onChanged,
    decoration: widget.decoration.copyWith(
      floatingLabelBehavior: widget.saved || widget.readOnly
          ? FloatingLabelBehavior.always
          : widget.decoration.floatingLabelBehavior,
      hintText: widget.saved ? '••••••••（已保存）' : widget.decoration.hintText,
      errorText: _error ?? widget.decoration.errorText,
      suffixIcon: IconButton(
        tooltip: _loading
            ? '正在读取口令'
            : _visible
            ? '隐藏口令'
            : '显示口令',
        onPressed: widget.enabled && !_loading ? _toggle : null,
        icon: Icon(
          _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
    ),
  );
}
