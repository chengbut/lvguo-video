import SwiftUI

struct MineView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("设置（二期）", systemImage: "gearshape")
                    Label("关于绿果视频", systemImage: "info.circle")
                }
                Section {
                    Text("原生重写一期骨架：SwiftUI + AVPlayer + JavaScriptCore")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
        }
    }
}
