import SwiftUI

// The pill on a freshly saved video that tells the user when their AI can
// find it:
//   • indexing — twinkling sparkles + a shimmering "Learning…"
//   • indexed  — a bouncing check, "Ready to ask", and a one-off sparkle burst
//   • failed   — a calm warning
// Motion respects Reduce Motion.

struct IndexBadgeView: View {
    let state: IndexStatusStore.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burst = false

    var body: some View {
        HStack(spacing: 5) {
            icon
            label
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
        .overlay { if burst && !reduceMotion { SparkleBurst().allowsHitTesting(false) } }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state)
        .onChange(of: state) { _, new in
            guard new == .indexed else { return }
            burst = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { burst = false }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .indexing:
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: !reduceMotion)
        case .indexed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .transition(.scale.combined(with: .opacity))
                .symbolEffect(.bounce, value: state)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch state {
        case .indexing:
            ShimmerText("Learning…", active: !reduceMotion)
        case .indexed:
            Text("Ready to ask")
                .font(.system(size: 11, weight: .medium))
                .transition(.push(from: .bottom))
        case .failed:
            Text("Not searchable")
                .font(.system(size: 11, weight: .medium))
        }
    }

    private var borderColor: Color {
        switch state {
        case .indexing: return Color.accentColor.opacity(0.20)
        case .indexed:  return Color.accentColor.opacity(0.35)
        case .failed:   return Color.orange.opacity(0.35)
        }
    }

    private var accessibilityText: String {
        switch state {
        case .indexing: return "Your AI will be able to find this video in a few seconds"
        case .indexed:  return "Ready: your AI can find this video"
        case .failed:   return "This video couldn't be made searchable"
        }
    }
}

/// Secondary text with a soft highlight sweeping across it.
private struct ShimmerText: View {
    let text: String
    let active: Bool
    @State private var phase: CGFloat = -1
    init(_ text: String, active: Bool) { self.text = text; self.active = active }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .overlay {
                if active {
                    LinearGradient(colors: [.clear, Color.accentColor.opacity(0.9), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 30)
                        .offset(x: phase * 40)
                        .mask(Text(text).font(.system(size: 11, weight: .medium)))
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Six tiny sparkles that fly out once — the "it's ready" moment.
struct SparkleBurst: View {
    @State private var out = false
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) / 6 * 2 * .pi
                Image(systemName: "sparkle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .offset(x: out ? cos(angle) * 26 : 0, y: out ? sin(angle) * 14 : 0)
                    .scaleEffect(out ? 0.4 : 1)
                    .opacity(out ? 0 : 1)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { out = true } }
    }
}
