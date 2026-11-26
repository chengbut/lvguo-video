import SwiftUI

struct HomeView: View {
    @State private var sourceKind: SourceKind = .station

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlassSegmentedControl(selection: $sourceKind)

                    // 玻璃信息卡：证明页面内同样是原生玻璃材质，不只是底栏
                    VStack(alignment: .leading, spacing: 6) {
                        Text("绿果视频 · 原生版")
                            .font(.headline)
                        Text(sourceKind == .station
                            ? "站源模式：二期接入 JS 模块系统后，这里显示模块的推荐内容。"
                            : "文件源模式：二期接入 WebDAV / FTP / HTTP 与云盘后，这里按文件夹浏览文件。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .glassEffect(.regular.tint(.green.opacity(0.10)), in: RoundedRectangle(cornerRadius: 20))

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(0..<6, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.quaternary)
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .overlay {
                                    Text("占位 \(index + 1)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("首页")
        }
    }
}
