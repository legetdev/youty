import SwiftUI
import AppKit

// Settings sheet. Hosts the user-visible preferences that affect saved
// bundles: vault location, frame-density caps, transcription language.
//
// Liquid-glass aesthetic — translucent HUD-style window with the same
// material treatment as the rest of the app.

struct SettingsView: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var vault: VaultManager
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header

                vaultSection
                Divider().opacity(0.35)

                frameSection
                Divider().opacity(0.35)

                languageSection
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Vault

    private var vaultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Vault")
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                if let url = vault.vaultURL {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No vault selected")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(vault.vaultURL == nil ? "Choose…" : "Change…") {
                    vault.chooseVault()
                }
                .controlSize(.regular)
            }
            if let url = vault.vaultURL {
                Text(url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Frame density

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Frame density")
            HStack(spacing: 16) {
                pickerColumn("Frames per save",
                              selection: $settings.frameCountCap,
                              options: SettingsStore.frameCountOptions)
                pickerColumn("Max frames / second",
                              selection: $settings.fpsCapStored,
                              options: SettingsStore.fpsOptions)
            }
            Text(densityHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Inline preview of what the current pair will produce on a "typical"
    /// 30-second short and a 10-minute talk — gives the user immediate
    /// feedback on how the two caps interact.
    private var densityHint: String {
        let cap = settings.frameCountCap
        let fps = settings.fpsCap
        func framesFor(_ s: Double) -> Int {
            min(cap, max(1, Int(floor(s * fps))))
        }
        let short = framesFor(30)
        let medium = framesFor(600)
        return "Examples: a 30-second clip → \(short) frames, a 10-minute video → \(medium) frames."
    }

    // MARK: - Language

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Transcription language")
            Picker("", selection: $settings.transcriptionLocaleIdentifier) {
                ForEach(SettingsStore.localeOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Used by Instagram and TikTok. YouTube transcripts are scraped directly from the platform.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    /// Segmented picker bound to a Hashable value. Used twice — once for
    /// frame count, once for fps.
    private func pickerColumn<V: Hashable>(_ label: String,
                                            selection: Binding<V>,
                                            options: [SettingsStore.Option<V>]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity)
    }
}
