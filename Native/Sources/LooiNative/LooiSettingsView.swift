import SwiftUI
import GoogleSignIn

struct LooiSettingsView: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var app: LooiAppModel
    @ObservedObject var settings: LooiSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft = LooiAIConfiguration()
    @State private var key = ""
    @State private var message = ""
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(L("语言"))) {
                    Picker(L("界面语言"), selection: $localization.selection) {
                        Text(L("跟随系统")).tag(LooiAppLanguage.system)
                        Text("简体中文").tag(LooiAppLanguage.chinese)
                        Text("English").tag(LooiAppLanguage.english)
                    }.disabled(app.phase != .idle)
                    Text(L("AI 会优先使用你输入或说话的语言；界面语言只作为没有语言线索时的默认值。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(header: Text(L("AI 服务"))) {
                    Picker(L("提供商"), selection: $draft.provider) {
                        ForEach(LooiProvider.all) { provider in Text(L(provider.title)).tag(provider.id) }
                    }.onChange(of: draft.provider, perform: selectProvider)
                    if !draft.preset.liveModels.isEmpty {
                        Picker(L("交互方式"), selection: $draft.mode) { Text(L("实时语音与视觉")).tag("live"); Text(L("文字与视觉")).tag("text") }
                    }
                    if !draft.isOffline {
                        LooiModelField(title: draft.isLive ? L("实时模型") : L("文字 / 视觉模型"), model: draft.isLive ? $draft.liveModel : $draft.model, choices: draft.isLive ? draft.preset.liveModels : draft.preset.models)
                    }
                }
                if draft.provider == "vertex" {
                    Section(header: Text(L("Google Cloud 项目"))) {
                        Picker(L("认证"), selection: $draft.auth) { Text(L("个人 Cloud Key")).tag("apiKey"); Text(L("Google 授权")).tag("oauth") }
                        Picker(L("端点"), selection: $draft.endpointType) { Text(L("标准项目")).tag("standard"); Text(L("Express（文字）")).tag("express") }
                        input(L("项目 ID"), text: $draft.projectId)
                        input(L("区域"), text: $draft.region)
                        if draft.auth == "oauth" { Button(L("Google 授权"), action: authorize) }
                    }
                }
                if !["gemini", "vertex", "rule", "mock"].contains(draft.provider) {
                    Section(header: Text(L("服务地址"))) { input(L("HTTPS 或局域网服务地址"), text: $draft.baseUrl) }
                }
                if !draft.isOffline && draft.auth != "oauth" && draft.provider != "ollama" {
                    Section(header: Text(L("凭据")), footer: Text(L("凭据存入 iOS 钥匙串。留空会保留已有密钥。"))) {
                        SecureField("API Key", text: $key).textContentType(.password).autocapitalization(.none).disableAutocorrection(true)
                        Button(L("删除此提供商的密钥"), role: .destructive, action: deleteKey)
                    }
                }
                Section {
                    Button(L("保存配置"), action: saveAndClose).disabled(app.isBusy)
                    Button(L("保存并测试 AI"), action: saveAndTest).disabled(app.phase != .idle)
                    if !message.isEmpty { Text(LM(message)).font(.footnote).foregroundStyle(.secondary) }
                    Text(LM(app.notice)).font(.footnote).foregroundStyle(.secondary)
                    if !app.textReply.isEmpty { Text(app.textReply).font(.subheadline).lineLimit(4) }
                }
                Section(header: Text(L("应用与权限"))) {
                    Button(L("打开系统权限设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    Text(L("SwiftUI 原生界面 · 原生音视频 · 原生蓝牙")).font(.caption).foregroundStyle(.secondary)
                    Text(L("实时模型用于语音通话；文字模型用于文字与视觉。下拉项是便捷预设，也可以直接输入自定义模型。Ollama 模型需先在电脑上安装。")).font(.caption).foregroundStyle(.secondary)
                    Text(L("文字交流默认不附带画面。需要分享图片时，请选择支持视觉的模型，例如 qwen-vl-plus 或 gemma3:4b，再点击输入框旁的图片按钮。")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L("AI 与设置"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } } }
            .onAppear { draft = settings.configuration }
        }.navigationViewStyle(.stack)
    }
    private func input(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).autocapitalization(.none).disableAutocorrection(true)
    }
    private func selectProvider(_ provider: String) { draft = settings.profile(provider); key = ""; message = "" }
    private func save(close: Bool, test: Bool = false) {
        Task {
            do {
                if app.phase != .idle { await app.stop() }
                draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.liveModel = draft.liveModel.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "models/", with: "")
                if draft.model.isEmpty { draft.model = draft.preset.models.first ?? "" }
                if draft.liveModel.isEmpty { draft.liveModel = draft.preset.liveModels.first ?? "" }
                if !draft.isOffline && (draft.isLive ? draft.liveModel : draft.model).isEmpty { throw LooiError.message("请选择或输入模型名称") }
                if draft.provider == "vertex" && draft.endpointType == "express" && (draft.isLive || draft.auth == "oauth") { throw LooiError.message("Express 请选择文字模式和个人 Cloud Key") }
                try settings.save(draft, key: key); key = ""; message = "配置已保存"
                if test { app.testAI() }
                if close { dismiss() }
            } catch { message = LooiAIRequest.redact(error.localizedDescription) }
        }
    }
    private func saveAndClose() { save(close: true) }
    private func saveAndTest() { save(close: false, test: true) }
    private func authorize() { Task { do { try await LooiCredentials.authorize(); message = "Google 授权完成" } catch { message = error.localizedDescription } } }
    private func deleteKey() { Task { await app.stop(); do { try LooiKeychain.delete(draft.credentialRef); key = ""; message = "密钥已删除" } catch { message = error.localizedDescription } } }
}

private struct LooiModelField: View {
    @ObservedObject private var localization = LooiLocalization.shared
    let title: String
    @Binding var model: String
    let choices: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                if !choices.isEmpty {
                    Menu {
                        ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                            Button(index == 0 ? L("%@（默认）", choice) : choice) { model = choice }
                        }
                    } label: { Label(L("选择模型"), systemImage: "chevron.down") }
                }
            }
            TextField(L("输入或选择模型名称"), text: $model).font(.system(.subheadline, design: .monospaced)).autocapitalization(.none).disableAutocorrection(true)
        }.padding(.vertical, 5)
    }
}
