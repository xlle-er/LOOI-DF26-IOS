import SwiftUI

struct LooiOTAProgress: View {
    let value: Double?
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value {
                ProgressView(value: min(1, max(0, value)), total: 1).progressViewStyle(.linear)
                Text(LM(label) + " · " + String(Int(min(1, max(0, value)) * 100)) + "%").font(.caption).monospacedDigit()
            } else {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.accentColor.opacity(0.15))
                        Capsule().fill(Color.accentColor).frame(width: geometry.size.width * 0.3)
                            .offset(x: reduceMotion ? geometry.size.width * 0.35 : (animating ? geometry.size.width : -geometry.size.width * 0.3))
                    }.clipped()
                }.frame(height: 6)
                    .onAppear { if !reduceMotion { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { animating = true } } }
                    .onDisappear { animating = false }
                if !label.isEmpty { Text(LM(label)).font(.caption) }
            }
        }.accessibilityIdentifier("otaProgress")
    }
}
