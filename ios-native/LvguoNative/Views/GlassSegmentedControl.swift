import SwiftUI

/// 站源 / 文件源切换（与 Flutter 版信息架构一致：首页与历史页顶部同款分段开关）
enum SourceKind: String, CaseIterable, Identifiable {
    case station = "站源"
    case file = "文件源"

    var id: String { rawValue }
    var title: String { rawValue }
}

/// iOS 26 原生液态玻璃分段控件：
/// 外壳与选中胶囊都是真 glassEffect 材质，选中胶囊用 glassEffectID 在容器内形变移动，不是贴图。
struct GlassSegmentedControl: View {
    @Binding var selection: SourceKind
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(SourceKind.allCases) { kind in
                    ZStack {
                        if selection == kind {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .glassEffect(
                                    .regular.tint(.green.opacity(0.35)).interactive(),
                                    in: Capsule()
                                )
                                .glassEffectID("selection", in: glassNamespace)
                        }
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                selection = kind
                            }
                        } label: {
                            Text(kind.title)
                                .font(.subheadline.weight(selection == kind ? .semibold : .regular))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .fixedSize()
                }
            }
            .padding(5)
            .glassEffect(.regular, in: Capsule())
        }
    }
}
