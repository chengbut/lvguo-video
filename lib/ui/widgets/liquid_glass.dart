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
    this.tint = 1.0,
    this.specular = false,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  /// 玻璃底色的浓度：1 为默认，0 为完全透明（只留实时模糊 + 细边框，
  /// 后面的内容直接透出来）。
  final double tint;

  /// 向 iOS 26 原生玻璃靠拢的边缘处理（默认关，只给底栏胶囊等
  /// 标志性表面开）：顶部高光线 + 顶部柔光带 + 底部暗线 + 一圈极淡的
  /// 色散渐变描边，模拟玻璃边缘的折射感。见 [GlassEdgeOverlay]。
  final bool specular;

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
              // 顶部高光到底部渐暗，模拟玻璃的光泽；tint 缩放底色浓度。
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: dark
                    ? [
                        Colors.white.withValues(alpha: .22 * tint),
                        Colors.white.withValues(alpha: .07 * tint),
                        Colors.white.withValues(alpha: .14 * tint),
                      ]
                    : [
                        Colors.white.withValues(alpha: .55 * tint),
                        Colors.white.withValues(alpha: .28 * tint),
                        Colors.white.withValues(alpha: .42 * tint),
                      ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: dark ? .28 : .5),
                width: 1,
              ),
            ),
            child: specular
                ? Stack(
                    children: [
                      child,
                      Positioned.fill(
                        child: GlassEdgeOverlay(borderRadius: borderRadius),
                      ),
                    ],
                  )
                : child,
          ),
        ),
      ),
    );
  }
}

/// 玻璃边缘高光层（不拦截手势）：顶部一条亮线（中间亮、两端收）、
/// 上半部一道柔光带、底部一条暗线，再加一圈极淡的色散渐变描边
/// （红→橙→绿→蓝→紫，alpha 约 0.18），模拟 iOS 26 原生液态玻璃
/// 边缘的折射彩边。Flutter 模拟做不出真正的折射，这里只做观感靠拢。
class GlassEdgeOverlay extends StatelessWidget {
  const GlassEdgeOverlay({super.key, required this.borderRadius});

  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: CustomPaint(
        painter: _GlassEdgePainter(borderRadius: borderRadius, dark: dark),
        size: Size.infinite,
      ),
    );
  }
}

class _GlassEdgePainter extends CustomPainter {
  const _GlassEdgePainter({required this.borderRadius, required this.dark});

  final BorderRadius borderRadius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outer = borderRadius.toRRect(rect);
    canvas.save();
    canvas.clipRRect(outer);
    // 顶部高光线：横向中间最亮、向两端渐隐。
    final topLine = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: dark ? .5 : .7),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0, .5, 1],
      ).createShader(Rect.fromLTWH(0, 0, size.width, 2));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 1.4), topLine);
    // 顶部柔光带：上半部由亮渐隐，模拟玻璃上沿的受光面。
    final sheen = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: dark ? .10 : .16),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0, 1],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * .5));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height * .5), sheen);
    // 底部暗线：和顶部亮线成对，衬出玻璃厚度。
    final bottomLine = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withValues(alpha: 0),
          Colors.black.withValues(alpha: dark ? .35 : .2),
          Colors.black.withValues(alpha: 0),
        ],
        stops: const [0, .5, 1],
      ).createShader(Rect.fromLTWH(0, size.height - 2, size.width, 2));
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - 1.4, size.width, 1.4),
      bottomLine,
    );
    canvas.restore();
    // 色散描边：一圈极淡的彩虹渐变，收在圆角内侧 0.5px。
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = const SweepGradient(
        colors: [
          Color(0x2EFF8A80),
          Color(0x2EFFD180),
          Color(0x2ECCFF90),
          Color(0x2E80D8FF),
          Color(0x2EEA80FC),
          Color(0x2EFF8A80),
        ],
      ).createShader(rect);
    canvas.drawRRect(outer.deflate(.5), edge);
  }

  @override
  bool shouldRepaint(covariant _GlassEdgePainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.borderRadius != borderRadius;
}

/// 液态玻璃提示条：全 App 的 SnackBar 统一走这里。默认 SnackBar 是
/// inverseSurface 实心黑条，和全 App 的玻璃质感不搭；这里把条本身设成
/// 透明无阴影，内容换成 LiquidGlass（实时模糊 + 高光渐变），文字用
/// onSurface（亮色玻璃上是深字、暗色玻璃上是浅字，都读得清）。
/// actionLabel/onAction 对应原来的 SnackBarAction：点了先关条再执行，
/// 和系统行为一致。悬浮位置仍由主题的 snackBarTheme 管（胶囊上方）。
SnackBar glassSnackBar(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  bool persist = false,
  Duration? duration,
}) {
  final theme = Theme.of(context);
  final textStyle = (theme.textTheme.bodyMedium ?? const TextStyle())
      .copyWith(color: theme.colorScheme.onSurface);
  return SnackBar(
    persist: persist,
    duration:
        duration ??
        Duration(seconds: actionLabel != null ? 6 : 4),
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    content: LiquidGlass(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: EdgeInsets.fromLTRB(16, 12, actionLabel == null ? 16 : 8, 12),
      child: Row(
        children: [
          Expanded(child: Text(message, style: textStyle)),
          if (actionLabel != null)
            TextButton(
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                onAction?.call();
              },
              child: Text(actionLabel),
            ),
        ],
      ),
    ),
  );
}

/// 液态玻璃分段开关：一排等宽选项，选中项下面垫一块滑动的实心胶囊，
/// 质感和底栏胶囊一致（发现页顶部的「站源 / 文件源」切换用）。
class GlassSegmentedControl extends StatelessWidget {
  const GlassSegmentedControl({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
  });
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final index = selected.clamp(0, labels.length - 1);
    return LiquidGlass(
      borderRadius: BorderRadius.circular(22),
      blur: 20,
      child: SizedBox(
        height: 44,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final segment = constraints.maxWidth / labels.length;
            return Stack(
              children: [
                AnimatedAlign(
                  alignment: Alignment(
                    labels.length > 1
                        ? -1 + 2 * index / (labels.length - 1)
                        : 0,
                    0,
                  ),
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutBack,
                  child: SizedBox(
                    width: segment,
                    height: 44,
                    child: Center(
                      child: Container(
                        width: segment - 6,
                        height: 36,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: colors.secondaryContainer.withValues(
                            alpha: .85,
                          ),
                          // 选中胶囊顶部压一层高光渐变（上亮下无），
                          // 滑动时像光扫过玻璃面。
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: .38),
                              Colors.white.withValues(alpha: 0),
                            ],
                            stops: const [0, .55],
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .35),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Material(
                  type: MaterialType.transparency,
                  child: Row(
                    children: [
                      for (final (i, label) in labels.indexed)
                        Expanded(
                          child: InkWell(
                            onTap: () => onSelected(i),
                            customBorder: const StadiumBorder(),
                            child: Center(
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: i == index
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: i == index
                                      ? colors.onSecondaryContainer
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
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
