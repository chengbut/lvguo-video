import 'dart:ui';

import 'package:flutter/material.dart';

/// Liquid Glass 风格的玻璃拟态容器。
///
/// 注意：这不是 iOS 26 原生的 Liquid Glass（SwiftUI `.glassEffect()`），
/// Flutter 3.47 没有暴露原生 Liquid Glass API；这里用 BackdropFilter
/// 实时模糊 + 半透明渐变 + 细边框高光模拟最接近的质感。只做视觉包装，
/// 不改任何交互与业务逻辑。
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.blur = 18,
    this.padding,
    this.margin,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .35 : .18),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              // 顶部高光到底部渐暗，模拟玻璃的光泽。
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: dark
                    ? [
                        Colors.white.withValues(alpha: .22),
                        Colors.white.withValues(alpha: .07),
                        Colors.white.withValues(alpha: .14),
                      ]
                    : [
                        Colors.white.withValues(alpha: .55),
                        Colors.white.withValues(alpha: .28),
                        Colors.white.withValues(alpha: .42),
                      ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: dark ? .28 : .5),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 玻璃质感的圆形图标按钮（播放器控制栏用）。
class LiquidGlassIconButton extends StatelessWidget {
  const LiquidGlassIconButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.tooltip,
    this.size = 44,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      borderRadius: BorderRadius.circular(size / 2),
      blur: 14,
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          onPressed: onPressed,
          icon: child,
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            fixedSize: Size.square(size),
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}
