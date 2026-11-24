import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'liquid_glass.dart';

/// 原生 iOS 液态玻璃的自适应封装。
///
/// iOS 上用原生 [UiKitView]（`lvguo/native_glass`，见
/// ios/Runner/AppDelegate.swift）做玻璃底：iOS 26+ 走系统
/// [UIGlassEffect]，老系统回退 [UIBlurEffect]；Flutter 内容画在上面。
/// 非 iOS 平台直接用现有的 Flutter 模拟 [LiquidGlass]。
///
/// 注意：
/// - 原生玻璃是 PlatformView：它是不透明的矩形层，Flutter 的模糊/渐变/
///   高光边框画不上去，所以高光边框和投影仍由 Flutter 层补（和
///   LiquidGlass 同一套参数），玻璃本体由原生负责。
/// - 触摸穿透：原生视图本身不接收手势（isUserInteractionEnabled = false，
///   加 hitTestBehavior: transparent），点击由上层的 Flutter 内容处理。
enum NativeGlassStyle {
  /// 常规玻璃（磨砂 + 轻微着色），对应 UIGlassEffect(style: .regular)。
  regular,

  /// 完全透明的玻璃，只留折射边缘，对应 UIGlassEffect(style: .clear)。
  clear,
}

class AdaptiveGlass extends StatelessWidget {
  const AdaptiveGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.blur = 18,
    this.tint = 1.0,
    this.padding,
    this.margin,
    this.style = NativeGlassStyle.regular,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final double tint;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final NativeGlassStyle style;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return LiquidGlass(
        borderRadius: borderRadius,
        blur: blur,
        tint: tint,
        padding: padding,
        margin: margin,
        child: child,
      );
    }
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: const Color(0x1A000000),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          children: [
            Positioned.fill(child: _NativeGlassView(style: style)),
            if (padding != null)
              Padding(padding: padding!, child: child)
            else
              child,
            // 原生玻璃本体没有高光边框，这里补一层和模拟版一致的细边，
            // 否则 iOS 上的胶囊会比 Android 少一圈亮边。
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    border: Border.all(
                      color: const Color(0x4DFFFFFF),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NativeGlassView extends StatelessWidget {
  const _NativeGlassView({this.style = NativeGlassStyle.regular});

  final NativeGlassStyle style;

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      viewType: 'lvguo/native_glass',
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      creationParams: <String, dynamic>{'style': style.name},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}

/// AdaptiveGlass 版的圆形玻璃图标按钮，和 LiquidGlassIconButton 同款用法。
class AdaptiveGlassIconButton extends StatelessWidget {
  const AdaptiveGlassIconButton({
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
    final radius = BorderRadius.circular(size / 2);
    return AdaptiveGlass(
      borderRadius: radius,
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
