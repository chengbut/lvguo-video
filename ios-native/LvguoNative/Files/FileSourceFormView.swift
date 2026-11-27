import SwiftUI

/// 添加文件源：先选类型（顺序固定：天翼、中国移动、夸克、
/// WebDAV、HTTP 拉取、FTP——前两项对齐 Flutter
/// addFileSource，夸克为修复轮 11 新增），再进对应表单。
struct FileSourceTypePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: FileSourceType?

    var body: some View {
        NavigationStack {
            List {
                ForEach(FileSourceType.allCases) { type in
                    Button {
                        chosen = type
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.label)
                                .foregroundStyle(.primary)
                            Text(subtitle(type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("添加文件源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(item: $chosen) { type in
                FileSourceFormView(type: type)
            }
        }
    }

    private func subtitle(_ type: FileSourceType) -> String {
        switch type {
        case .tianyi, .mobile: return "网页登录（实验）/ WebDAV 挂载"
        case .quark: return "网页登录（实验）"
        case .webdav: return "WebDAV 服务器"
        case .http: return "单个媒体文件的直链地址"
        case .ftp: return "FTP 服务器"
        }
    }
}

/// 文件源表单：字段随类型/接入方式变化（对齐 Flutter
/// FileSourceFormPage）。天翼/移动两种接法：原生登录（网页登录
/// 或粘贴凭据）与 WebDAV 挂载。
struct FileSourceFormView: View {
    let type: FileSourceType

    @EnvironmentObject private var fileStore: FileSourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var url = ""
    @State private var portText = ""
    @State private var path = ""
    /// 接入方式：native / webdav（仅天翼/移动可选）
    @State private var mode = FileSourceMode.native
    /// 原生登录凭据：网页登录抓到的或手动粘贴的
    @State private var credential = ""
    @State private var loginDone = false

    private var isCloud: Bool { type == .tianyi || type == .mobile || type == .quark }
    /// 接入方式可选（原生/WebDAV）的只有天翼/移动；夸克
    /// 没有官方 WebDAV，恒走原生登录（修复轮 11）
    private var canPickMode: Bool { type == .tianyi || type == .mobile }

    private var canSave: Bool {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        switch type {
        case .http:
            return !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .ftp, .webdav:
            return !server.trimmingCharacters(in: .whitespaces).isEmpty
        case .tianyi, .mobile, .quark:
            if mode == FileSourceMode.native {
                return !credential.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return !server.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        Form {
            Section("名称") {
                TextField("显示名称", text: $name)
            }
            if canPickMode {
                Section("接入方式") {
                    Picker("接入方式", selection: $mode) {
                        Text("原生登录（实验）").tag(FileSourceMode.native)
                        Text("WebDAV 挂载").tag(FileSourceMode.webDav)
                    }
                    .pickerStyle(.segmented)
                }
            }
            switch type {
            case .http:
                Section("直链地址") {
                    TextField("https://…/video.mp4", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            case .ftp:
                serverSection
                Section("端口与目录") {
                    TextField("端口（留空 = 21）", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("初始目录（留空 = 根目录）", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                accountSection
            case .webdav:
                serverSection
                accountSection
            case .tianyi, .mobile, .quark:
                if mode == FileSourceMode.native {
                    nativeSection
                } else {
                    serverSection
                    accountSection
                }
            }
        }
        .navigationTitle("添加\(type.label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!canSave)
            }
        }
    }

    private var serverSection: some View {
        Section("服务器") {
            TextField("服务器地址", text: $server)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var accountSection: some View {
        Section("账号") {
            TextField("用户名", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $password)
        }
    }

    private var nativeSection: some View {
        Section {
            NavigationLink {
                CloudLoginView(type: type) { captured in
                    credential = captured
                    loginDone = true
                }
            } label: {
                Label(
                    loginDone ? "已读取登录状态（点此可重登）" : "打开网页登录",
                    systemImage: "person.crop.circle.badge.checkmark"
                )
            }
            Text("或手动粘贴凭据（备用方式）：")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                type == .mobile ? "authorization 令牌或整段 Cookie" : "Cookie 整段",
                text: $credential,
                axis: .vertical
            )
            .lineLimit(3...6)
            .font(.footnote)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
            Text("原生登录（实验）")
        } footer: {
            Text(nativeFooterText)
        }
    }

    private var nativeFooterText: String {
        switch type {
        case .tianyi:
            return "天翼用 Cookie 整段；保存前建议先用网页登录自动验证。"
        case .quark:
            return "夸克用 Cookie 整段；保存前建议先用网页登录自动验证。"
        default:
            return "移动用 authorization 令牌（Authorization: Basic 后面的内容），或整段 Cookie，客户端会自动判断。"
        }
    }

    private func save() {
        let source = FileSource(
            id: newFileSourceId(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            server: server.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: type == .quark ? FileSourceMode.native
                : (isCloud ? mode : FileSourceMode.webDav),
            cookie: credential.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(portText) ?? 0,
            path: path.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        fileStore.add(source)
        dismiss()
    }
}

/// 文件源卡片行（首页文件模式与资源页共用）：名称 + 类型 + 主机
struct FileSourceRow: View {
    let source: FileSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.nativeMode ? "cloud" : "externaldrive")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(source.type.label) · \(source.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
