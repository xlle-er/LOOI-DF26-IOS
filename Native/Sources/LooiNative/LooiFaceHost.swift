import SwiftUI
import WebKit
import Combine

private final class LooiFaceMessages: NSObject, WKScriptMessageHandler {
    weak var host: LooiFaceHost?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let object = message.body as? [String: Any] else { return }
        Task { @MainActor [weak self] in await self?.host?.receive(object) }
    }
}

@MainActor final class LooiFaceHost: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var ready = false
    @Published private(set) var error = ""
    let webView: WKWebView
    var onCommand: (([String: Any]) async throws -> [String: Any])?
    var onPhoto: (() throws -> Data)?
    private let messages = LooiFaceMessages()
    private var latestState: [String: Any] = [:]
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        messages.host = self
        configuration.userContentController.add(messages, name: "face")
        webView.navigationDelegate = self
        webView.isOpaque = false; webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        load()
    }
    private func load() {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Face") else {
            error = "眼睛资源缺失，请重新构建 App"; return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    func state(connected: Bool, speaking: Bool, thinking: Bool, cameraRunning: Bool) {
        latestState = ["connected": connected, "speaking": speaking, "thinking": thinking, "cameraRunning": cameraRunning]
        guard ready else { return }
        call("window.looiFace.state(state)", arguments: ["state": latestState])
    }
    func run(_ name: String, allowMotion: Bool) async throws {
        guard ready else { throw LooiError.message("眼睛和动作组件正在准备，请稍后重试") }
        let result = try await webView.callAsyncJavaScript("return await window.looiFace.run(name, allowMotion)", arguments: ["name": name, "allowMotion": allowMotion], in: nil, contentWorld: .page)
        if let result = result as? [String: Any], result["ok"] as? Bool == false || result["partial"] as? Bool == true {
            throw LooiError.message(result["reason"] as? String ?? "动作未全部完成，请检查身体连接")
        }
    }
    func cancel() { guard ready else { return }; webView.evaluateJavaScript("window.looiFace.cancel()", completionHandler: nil) }
    fileprivate func receive(_ object: [String: Any]) async {
        if object["kind"] as? String == "ready" {
            ready = true; error = ""
            call("window.looiFace.state(state)", arguments: ["state": latestState])
            return
        }
        guard let id = object["id"] as? String else { return }
        do {
            let result: Any
            if object["kind"] as? String == "command", let payload = object["payload"] as? [String: Any], let onCommand { result = try await onCommand(payload) }
            else if object["kind"] as? String == "photo", let onPhoto { result = "data:image/jpeg;base64,\(try onPhoto().base64EncodedString())" }
            else { throw LooiError.message("不支持的组件请求") }
            call("window.looiFace.reply(id, value, null)", arguments: ["id": id, "value": result])
        } catch {
            call("window.looiFace.reply(id, null, error)", arguments: ["id": id, "error": error.localizedDescription])
        }
    }
    private func call(_ script: String, arguments: [String: Any]) {
        Task { _ = try? await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL,
              let root = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Face")?.deletingLastPathComponent(),
              url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; load() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = "眼睛组件加载失败：\(error.localizedDescription)" }
}

struct LooiEyesView: UIViewRepresentable {
    let face: LooiFaceHost
    func makeUIView(context: Context) -> WKWebView { face.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
