import SwiftUI

// Observe the session directly so an incoming status reply updates every visible entry point.
struct LooiWiringNotice: View {
    @ObservedObject private var localization = LooiLocalization.shared
    @ObservedObject var session: LooiDeviceSession
    let connected: Bool
    let configure: () -> Void
    var body: some View {
        if connected && session.needsWiringConfiguration {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("接线未配置，机器人无法移动"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button(action: configure) {
                    Label(L("配置接线"), systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(.orange).foregroundStyle(.black)
                    .disabled(session.busy).accessibilityIdentifier("configureMotorWiring")
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.7), lineWidth: 1))
                .accessibilityIdentifier("motorWiringRequired")
        }
    }
}
