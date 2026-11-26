import SwiftUI

struct DownloadsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "暂无下载",
                systemImage: "arrow.down.circle",
                description: Text("下载功能在二期接入。")
            )
            .navigationTitle("下载")
        }
    }
}
