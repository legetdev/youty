import SwiftUI

// Small calm pill that reflects the indexing state of a freshly-saved
// bundle. Lives directly below the "X frames saved ✓" line in the
// saved-video row. Three states only:
//   • indexing — soft spinner + "Indexing…"
//   • indexed  — checkmark + "Indexed"
//   • failed   — warning + "Index failed"
//
// Visual language matches the rest of the success area: 11 pt secondary
// text, regularMaterial pill, thin hairline border. Deliberately quieter
// than the action buttons above it — it's a status surface, not a CTA.

struct IndexBadgeView: View {
    let state: IndexStatusStore.State

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .indexing:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 10, height: 10)
        case .indexed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orange)
        }
    }

    private var label: String {
        switch state {
        case .indexing: return "Indexing…"
        case .indexed:  return "Indexed"
        case .failed:   return "Index failed"
        }
    }

    private var textColor: Color {
        switch state {
        case .indexing: return .secondary
        case .indexed:  return .primary
        case .failed:   return .primary
        }
    }

    private var borderColor: Color {
        switch state {
        case .indexing: return .white.opacity(0.10)
        case .indexed:  return Color.accentColor.opacity(0.25)
        case .failed:   return Color.orange.opacity(0.35)
        }
    }

    private var accessibilityText: String {
        switch state {
        case .indexing: return "This video is being indexed in the background"
        case .indexed:  return "This video is indexed and searchable"
        case .failed: return "Indexing failed"
        }
    }
}
