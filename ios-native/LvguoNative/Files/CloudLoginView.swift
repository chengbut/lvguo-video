import SwiftUI
import WebKit

/// 网易爆米花式的内嵌网页登录（实验）：打开官方网页版登录页，
/// 用户自己输账号/短信验证码完成登录，点「完成」后读 WKWebView
/// 持久化 Cookie 存储里该域名的全部 Cookie（含 HttpOnly），再拿
/// 文件列表接口实际探活——探活通过才算登录成功（对齐 Dart
/// CloudLoginPage）。移动令牌就是 yun.139.com 下名为
/// authorization 的 Cookie 值；另外全量扫 localStorage /
/// sessionStorage（含嵌套 JSON）兜底，逐个探活。
struct CloudLoginView: View {
    let type: FileSourceType
    /// 探活通过后把凭据交给调用方（由调用方存成文件源）
    let onCredential: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CloudLoginModel

    init(type: FileSourceType, onCredential: @escaping (String) -> Void) {
        self.type = type
        self.onCredential = onCredential
        _model = StateObject(wrappedValue: CloudLoginModel(type: type))
    }

    private var home: URL {
        URL(string: type == .tianyi ? "https://cloud.189.cn/" : "https://yun.139.com/")!
    }

    var body: some View {
        VStack(spacing: 0) {
            CloudWebView(webView: model.webView, onPageFinished: { url in
                Task { await model.refreshHint(url: url) }
            })
            .ignoresSafeArea(edges: .bottom)
            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .navigationTitle("登录\(type.label)（实验）")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        if let credential = await model.finish() {
                            onCredential(credential)
                            dismiss()
                        }
                    }
                } label: {
                    if model.busy {
                        ProgressView()
                    } else {
                        Text("完成")
                    }
                }
                .disabled(model.busy)
            }
        }
        .onAppear {
            model.loadIfNeeded(home: home)
        }
    }
}

private struct CloudWebView: UIViewRepresentable {
    let webView: WKWebView
    let onPageFinished: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageFinished: onPageFinished)
    }

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPageFinished: (String) -> Void
        init(onPageFinished: @escaping (String) -> Void) {
            self.onPageFinished = onPageFinished
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPageFinished(webView.url?.absoluteString ?? "")
        }
    }
}

@MainActor
final class CloudLoginModel: ObservableObject {
    let type: FileSourceType
    @Published var status = "在官方页面里完成登录，然后点右上角「完成」。"
    @Published var busy = false

    /// 标准 iPhone Safari UA：移动/天翼登录页的短信验证码接口会
    /// 按 UA 与浏览器指纹拦截 WebView 默认 UA（实测教训，同 Dart）。
    /// Cookie 用默认（持久化）数据存储，不要改成无痕配置。
    let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 " +
            "Mobile/15E148 Safari/604.1"
        return webView
    }()

    private var loaded = false
    private var hintSequence = 0

    init(type: FileSourceType) {
        self.type = type
    }

    private var isTianyi: Bool { type == .tianyi }

    func loadIfNeeded(home: URL) {
        guard !loaded else { return }
        loaded = true
        webView.load(URLRequest(url: home))
    }

    static func looksLikeLoginPage(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("login") || lower.contains("passport") || lower.contains("signin")
    }

    /// 页面加载完刷新底部提示：只有「不在登录页」且「关键 Cookie
    /// 已存在」才提示已进入网盘（同 Dart 的判定与理由）
    func refreshHint(url: String) async {
        let sequence = hintSequence + 1
        hintSequence = sequence
        if busy { return }
        if Self.looksLikeLoginPage(url) {
            status = "请先在页面里完成登录，成功进入网盘后再点右上角「完成」。"
            return
        }
        let cookieMap = await readCookieMap()
        guard sequence == hintSequence, !busy else { return }
        let hasKeyCookie = isTianyi
            ? url.contains("cloud.189.cn") && !cookieMap.isEmpty
            : cookieMap.keys.contains { $0.lowercased() == "authorization" }
        status = hasKeyCookie
            ? "检测到已进入网盘页面，点右上角「完成」读取登录状态。"
            : "请先在页面里完成登录，成功进入网盘后再点右上角「完成」。"
    }

    /// 读 Cookie 存储里该服务域名下的全部 Cookie（名称 → 值），
    /// 再补一遍 document.cookie（非 HttpOnly 部分）
    func readCookieMap() async -> [String: String] {
        var byName: [String: String] = [:]
        let domains = isTianyi
            ? ["cloud.189.cn", "api.cloud.189.cn"]
            : ["yun.139.com", "personal-kd-njs.yun.139.com", "caiyun.139.com"]
        let cookies = await webView.configuration.websiteDataStore
            .httpCookieStore.allCookies()
        for cookie in cookies {
            let domain = cookie.domain.lowercased()
            if domains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) || $0.hasSuffix(domain) }) {
                if !cookie.name.isEmpty {
                    byName[cookie.name] = cookie.value
                }
            }
        }
        if let raw = try? await webView.evaluateJavaScript("document.cookie"),
           let text = raw as? String {
            for part in text.split(separator: ";") {
                guard let cut = part.firstIndex(of: "=") else { continue }
                let name = part[..<cut].trimmingCharacters(in: .whitespaces)
                let value = part[part.index(after: cut)...]
                    .trimmingCharacters(in: .whitespaces)
                if byName[name] == nil {
                    byName[name] = value
                }
            }
        }
        return byName
    }

    static func stripBasic(_ value: String) -> String {
        value.hasPrefix("Basic ") ? String(value.dropFirst(6))
            .trimmingCharacters(in: .whitespaces) : value
    }

    /// 移动云盘令牌兜底扫描：localStorage + sessionStorage 逐键看
    /// （脚本逐字对齐 Dart 版）
    func readStoredTokens() async -> [String] {
        let script =
            "(function(){var out=[];var seen={};" +
            "function push(v){if(typeof v!==\"string\")return;v=v.trim();" +
            "if(v.length>=16&&!seen[v]){seen[v]=1;out.push(v);}}" +
            "function walk(k,v){if(typeof v===\"string\"){" +
            "if(/auth|token/i.test(k))push(v);}" +
            "else if(v&&typeof v===\"object\"){for(var kk in v)walk(kk,v[kk]);}}" +
            "function scan(store){if(!store)return;" +
            "for(var i=0;i<store.length;i++){var k=store.key(i);" +
            "var raw=store.getItem(k);if(raw==null)continue;" +
            "try{walk(k,JSON.parse(raw));}catch(e){}" +
            "if(/auth|token/i.test(k))push(raw);}}" +
            "try{scan(localStorage);}catch(e){}" +
            "try{scan(sessionStorage);}catch(e){}" +
            "return JSON.stringify(out);})()"
        guard let raw = try? await webView.evaluateJavaScript(script),
              var text = raw as? String else {
            return []
        }
        if text.hasPrefix("\""),
           let data = text.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? String {
            text = decoded
        }
        guard let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return list.compactMap { item in
            let value = "\(item)".trimmingCharacters(in: .whitespaces)
            return value.count >= 16 ? Self.stripBasic(value) : nil
        }
    }

    /// 点「完成」：拼候选 → 逐个探活 → 返回第一个通过的凭据
    func finish() async -> String? {
        if busy { return nil }
        busy = true
        status = "正在读取登录状态并验证…"
        defer { busy = false }
        let cookieMap = await readCookieMap()
        let cookieHeader = cookieMap
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        var candidates: [String] = []
        func addCandidate(_ value: String?) {
            let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !v.isEmpty, !candidates.contains(v) {
                candidates.append(v)
            }
        }
        if !isTianyi {
            for (name, value) in cookieMap where name.lowercased() == "authorization" {
                addCandidate(Self.stripBasic(value.trimmingCharacters(in: .whitespaces)))
            }
            for token in await readStoredTokens() {
                addCandidate(token)
            }
        }
        addCandidate(cookieHeader)
        if candidates.isEmpty {
            status = "没有读到任何登录信息，可能还没登录成功，或登录态存在读不到的地方。可以再试一次，或返回用备用粘贴方式。"
            return nil
        }
        var lastError: Error?
        for credential in candidates {
            let probe = FileSource(
                id: "login-probe",
                name: type.label,
                type: type,
                mode: FileSourceMode.native,
                cookie: credential
            )
            do {
                _ = try await createFileSourceClient(probe).list(nil)
                return credential
            } catch {
                lastError = error
            }
        }
        status = "读到了登录信息，但接口验证没通过：\(lastError?.localizedDescription ?? "")。可以再试一次，或返回用备用粘贴方式。"
        return nil
    }
}
