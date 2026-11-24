import 'package:flutter/material.dart';

/// 一次性淡入：只在首次出现时播放，之后重建不再重复。
///
/// 用于设置分组、我的页面等列表首次出现时的轻量入场动画。
/// 状态保存在 State 里，父级重建不会重播，避免列表刷新时闪烁。
class FadeInOnce extends StatefulWidget {
  const FadeInOnce({super.key, required this.child});

  final Widget child;

  @override
  State<FadeInOnce> createState() => _FadeInOnceState();
}

class _FadeInOnceState extends State<FadeInOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 220),
    vsync: this,
  )..forward();
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _offset = Tween<Offset>(
    begin: const Offset(0, 0.02),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) => Opacity(
      opacity: _opacity.value,
      child: Transform.translate(
        offset: Offset(
          0,
          _offset.value.dy * MediaQuery.sizeOf(context).height,
        ),
        child: child,
      ),
    ),
    child: widget.child,
  );
}
