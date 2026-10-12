import SwiftUI
import AppKit

// Small interactive touches for the main window. Each one is subtle, quick,
// and switches off under Reduce Motion.

/// The header logo: drifts gently, leans toward the pointer, and does a little
/// hop when clicked.
struct LogoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var hops = 0

    var body: some View {
        Image("HeaderLogo")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 96)
            .rotationEffect(.degrees(hovering && !reduceMotion ? -6 : 0))
            .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)
            .shadow(color: Color.accentColor.opacity(hovering ? 0.35 : 0), radius: 14, y: 4)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: hops) { content, lift in
                content.offset(y: lift)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(-14, duration: 0.18)
                    SpringKeyframe(0, duration: 0.45, spring: .bouncy)
                }
            }
            .phaseAnimator(reduceMotion ? [0] : [0, 1]) { content, phase in
                content.offset(y: phase == 1 ? -2 : 1)
            } animation: { _ in .easeInOut(duration: 2.4) }
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { if !reduceMotion { hops += 1 } }
            .accessibilityLabel("youty")
    }
}

/// The settings gear turns a little when the pointer rests on it.
struct HoverSpinGear: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Image(systemName: "gearshape.fill")
            .symbolRenderingMode(.hierarchical)
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(hovering && !reduceMotion ? 60 : 0))
            .animation(.spring(response: 0.5, dampingFraction: 0.65), value: hovering)
            .onHover { hovering = $0 }
    }
}

private struct HoverLift: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && isEnabled && !reduceMotion ? 1.015 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// A gentle lift under the pointer, for primary controls.
    func hoverLift() -> some View { modifier(HoverLift()) }
}

/// One saved video in "Recently saved": lifts on hover, reveals an "open"
/// arrow, glows briefly when it's the one just saved, and shows when the AI
/// can find it.
struct RecentRow: View {
    let item: VaultLocalSearch.Match
    let symbol: String
    let state: IndexStatusStore.State?
    let highlighted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.folder])
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.channel)")
        .accessibilityHint("Shows the saved video in Finder")
        .scaleEffect(hovering && !reduceMotion ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .animation(.easeOut(duration: 0.6), value: highlighted)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state)
        .onHover { hovering = $0 }
        .contextMenu {
            if let url = URL(string: item.url) {
                Button("Open Original") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: hovering)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Text(item.channel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let state {
                IndexBadgeView(state: state)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .offset(x: hovering || reduceMotion ? 0 : -4)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(highlighted ? 0.14 : (hovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
    }
}

/// A friendly nudge before the first save.
struct EmptyLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce.up, options: .repeat(.periodic(delay: 2.5)), isActive: !reduceMotion)
            Text("Your library is empty — paste a link to start it.")
                .font(.system(size: 12, weight: .medium))
            Text("Every video you save becomes something your AI can quote.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
