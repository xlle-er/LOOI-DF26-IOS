import SwiftUI

struct LooiDeviceAccess: View {
    @ObservedObject var session: LooiDeviceSession
    @State private var value = ""
    @State private var error = ""
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { session.needsPassword || session.needsName }, set: { if !$0 { session.needsPassword = false; session.needsName = false } })) {
                NavigationView {
                    Form {
                        if session.needsPassword {
                            SecureField(L("设备管理密码"), text: $session.password)
                            Button(L("连接")) { session.run { do { try await session.authenticate() } catch { self.error = error.localizedDescription; throw error } } }.disabled(session.busy)
                        } else {
                            TextField(L("机器人名字（支持中文）"), text: $value)
                            Button(L("保存")) { session.run { try await session.rename(value) } }.disabled(session.busy)
                            Button(L("保留识别码")) { session.skipName() }
                        }
                        if !error.isEmpty { Text(LM(error)) }
                    }.navigationTitle(L(session.needsPassword ? "设备管理密码" : "给机器人起个名字"))
                    .toolbar { Button(L("稍后")) { if session.needsName { session.skipName() }; session.needsPassword = false } }
                }.navigationViewStyle(.stack).interactiveDismissDisabled(session.busy)
            }
    }
}
