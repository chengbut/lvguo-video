import SwiftUI

struct HistoryView: View {
    @State private var sourceKind: SourceKind = .station

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GlassSegmentedControl(selection: $sourceKind)
                    .padding(.top, 8)
                ContentUnavailableView(
                    sourceKind == .station ? "暂无站源历史" : "暂无文件记录",
                    systemImage: "clock",
                    description: Text("二期接入数据层后，这里显示观看历史并支持续播。")
                )
            }
            .navigationTitle("历史")
        }
    }
}
