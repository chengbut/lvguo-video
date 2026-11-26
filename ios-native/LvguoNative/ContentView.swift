import SwiftUI

/// 根视图：5 页 TabView。iOS 26 上 TabView 自带原生液态玻璃底栏，无需任何模拟。
struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
            HistoryView()
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            ResourcesView()
                .tabItem { Label("资源", systemImage: "square.stack.3d.up.fill") }
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
            MineView()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .tint(.green)
    }
}
