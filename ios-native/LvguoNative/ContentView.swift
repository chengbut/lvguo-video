import SwiftUI
import UIKit

/// 根视图：5 页 TabView。iOS 26 上 TabView 自带原生液态玻璃底栏，无需任何模拟。
/// 外观设置在此全局生效：主题模式 → preferredColorScheme、
/// 主题色板种子色 → 全局 tint、纯黑深色 → 窗口底色、
/// 「在主页底栏显示历史」→ 历史页签的显隐。
struct ContentView: View {
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
            if appearance.historyTab {
                HistoryView()
                    .tabItem {
                        Label("历史", systemImage: "clock.arrow.circlepath")
                    }
            }
            ResourcesView()
                .tabItem { Label("资源", systemImage: "square.stack.3d.up.fill") }
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
            MineView()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .tint(
            appearance.themeColor == .white
                ? Color.secondary : appearance.themeColor.seed
        )
        .preferredColorScheme(appearance.colorScheme)
        .onAppear { applyWindowBackground() }
        .onChange(of: appearance.pureBlack) { _, _ in
            applyWindowBackground()
        }
        .onChange(of: appearance.themeMode) { _, _ in
            applyWindowBackground()
        }
    }

    /// 纯黑深色模式的窗口级落地：深色生效时把窗口底色压成
    /// 纯黑（系统列表等容器底色仍由 iOS 决定，见 README 对齐表）
    private func applyWindowBackground() {
        let dark = appearance.themeMode == "dark"
            || (appearance.themeMode == "system"
                && UITraitCollection.current.userInterfaceStyle == .dark)
        let color: UIColor = appearance.pureBlack && dark
            ? .black : .systemBackground
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.backgroundColor = color
            }
        }
    }
}
