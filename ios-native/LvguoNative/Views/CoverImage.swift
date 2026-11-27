import SwiftUI

/// 封面模糊修饰器，对齐 Flutter CoverBlurScope.blurs：
/// 模糊按钮开启 && (本页是探索面 || 模糊所有界面) &&
/// (模式 = 全部 || (模式 = 仅限制级 && 该模块声明 adult))。
/// 首页眼睛按钮切换的是 CoverBlurState.mode（会话状态）。
struct CoverBlurModifier: ViewModifier {
    let source: String
    let explore: Bool

    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var blurState: CoverBlurState
    @EnvironmentObject private var moduleStore: ModuleStore

    func body(content: Content) -> some View {
        let adult = moduleStore.modules
            .first { $0.id == source }?.manifest?.adult == true
        let blurred = blurState.blurs(
            sourceIsAdult: adult, explore: explore, appearance: appearance
        )
        return content.blur(radius: blurred ? 16 : 0)
    }
}

extension View {
    /// 给封面图挂模糊判定：source 是封面所属模块 id，
    /// explore 表示首页/搜索这类探索面（不受「模糊所有界面」开关限制）
    func coverBlur(source: String, explore: Bool) -> some View {
        modifier(CoverBlurModifier(source: source, explore: explore))
    }
}
