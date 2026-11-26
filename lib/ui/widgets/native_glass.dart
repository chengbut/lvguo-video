import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
/// - [showBorder]：默认在玻璃上再补一圈 1pt 白边（和模拟版一致的细边，
///   否则 iOS 上的胶囊会比 Android 少一圈亮边）。小圆钮不要这圈边：
///   1pt 白边 + UIGlassEffect 自己的折射边叠在一起显粗、像槽，
///   用 [.clear] + showBorder: false，靠系统玻璃自己的边缘收边，
///   才是 iOS 原生圆钮的样子。
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
    this.showBorder = true,
    this.specular = false,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final double tint;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final NativeGlassStyle style;
  final bool showBorder;

  /// 边缘高光打磨（见 LiquidGlass.specular）：非 iOS 透传给模拟版；
  /// iOS 上原生玻璃自带折射边，再叠 Flutter 的高光线 + 色散描边
  /// （代替原来那圈纯白边）。
  final bool specular;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return LiquidGlass(
        borderRadius: borderRadius,
        blur: blur,
        tint: tint,
        padding: padding,
        margin: margin,
        specular: specular,
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
            // 原生玻璃本体没有高光边框，默认补一层和模拟版一致的细边，
            // 否则 iOS 上的胶囊会比 Android 少一圈亮边。showBorder
            // 为 false 时不补（小圆钮用 .clear + 无边，见上面）。
            if (showBorder)
              Positioned.fill(
                child: specular
                    ? GlassEdgeOverlay(borderRadius: borderRadius)
                    : IgnorePointer(
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
/// 小圆钮默认走 .clear 玻璃、不补白边：iOS 原生圆钮就是只有系统玻璃
/// 自己的边缘，没有额外一圈白边；.regular + 白边叠在一起显粗、像槽。
class AdaptiveGlassIconButton extends StatelessWidget {
  const AdaptiveGlassIconButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.tooltip,
    this.size = 44,
    this.style = NativeGlassStyle.clear,
    this.showBorder = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final NativeGlassStyle style;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size / 2);
    return AdaptiveGlass(
      borderRadius: radius,
      blur: 14,
      style: style,
      showBorder: showBorder,
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
