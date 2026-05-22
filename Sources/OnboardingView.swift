import SwiftUI
import AppKit

// First-launch onboarding (R.2). Four cards, completable in any order:
//   1. Pick a vault folder — required to save anything.
//   2. Paste a Gemini API key — optional, unlocks semantic search.
//   3. Install the `youty` command-line binary — copies the install
//      command + opens Terminal so the user can see what runs.
//   4. Wire up the `youty-mcp` server for Claude Desktop / Cursor /
//      any MCP client — copies the install + config snippet.
//
// Plus an always-visible footer disclosure card on ContentView (the
// IG/TikTok ToS posture mirroring yt-dlp). The footer is in
// ContentView itself, not here — this file owns only the multi-card
// sheet.
//
// All four cards remain reachable from Settings → Onboarding so the
// user can revisit them at any time.

struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var vault: VaultManager
    let onDismiss: () -> Void

    // Forces the gemini-key card to re-read the keychain whenever a save
    // happens, so the row flips from "pending" to "done" without a
    // window-cycle.
    @State private var apiKeyStored: Bool = KeychainHelper.exists(account: "youty",
                                                                    service: "gemini-api")
    @State private var apiKeyInput: String = ""
    @State private var apiKeyError: String?
    @State private var cliCopyConfirmed: Bool = false
    @State private var mcpCopyConfirmed: Bool = false

    private var vaultDone: Bool { vault.vaultURL != nil }
    private var geminiDone: Bool { apiKeyStored }
    /// "Done" for CLI/MCP is heuristic — we can't detect whether the
    /// user actually pasted the command into their terminal. Storing a
    /// "user pressed the button" flag in AppStorage is enough signal to
    /// stop nagging them on subsequent launches.
    private var cliDone: Bool { settings.onboardingCLIDone }
    private var mcpDone: Bool { settings.onboardingMCPDone }
    private var allDone: Bool { vaultDone && geminiDone && cliDone && mcpDone }
    private var requiredDone: Bool { vaultDone }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 26)
                    .padding(.top, 14)
                    .padding(.bottom, 14)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        intro

                        vaultCard
                        geminiCard
                        cliCard
                        mcpCard

                        disclosureCard
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 18)
                }

                footer
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
                    .background(.regularMaterial)
            }
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text("Set up Youty")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close onboarding")
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome.")
                .font(.system(size: 18, weight: .semibold))
            Text("Three quick steps to get the most out of Youty. The vault is required; everything else is optional and reachable from Settings → Onboarding any time.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Cards

    private var vaultCard: some View {
        card(number: 1, title: "Pick a vault folder", required: true, done: vaultDone) {
            VStack(alignment: .leading, spacing: 10) {
                Text("This is where your saved videos live — one folder per video, with the transcript markdown and frame JPEGs side by side. Pick somewhere you already sync (iCloud, Dropbox) if you want them on multiple Macs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    if let url = vault.vaultURL {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                            Text(url.path)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text("No folder selected")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button(vaultDone ? "Change…" : "Choose folder…") {
                        vault.chooseVault()
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Pick a vault folder")
                }
            }
        }
    }

    private var geminiCard: some View {
        card(number: 2, title: "Add a Gemini API key", required: false, done: geminiDone) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Optional. Lets Claude / Cursor / any MCP-compatible AI search your saved videos by meaning, not just keyword. Your vault stays local — only the transcript text is sent to Gemini, and only with the key you paste below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    SecureField(geminiDone ? "Replace stored key…" : "Paste your Gemini API key",
                                text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { saveGeminiKey() }
                        .accessibilityLabel("Gemini API key")
                    Button(geminiDone ? "Replace" : "Save") {
                        saveGeminiKey()
                    }
                    .controlSize(.small)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let err = apiKeyError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Link("Get a key →", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.system(size: 11))
                    if geminiDone {
                        Text("✓ Stored securely in macOS Keychain")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var cliCard: some View {
        card(number: 3, title: "Install the `youty` CLI", required: false, done: cliDone) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save, search and read transcripts from your terminal — same pipeline as the app, same vault. The button below copies the install command to your clipboard and opens Terminal so you can paste + run it. (Youty doesn't run anything outside the sandbox; this is yours to execute.)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                codeBlock(Self.cliInstallCommand)

                HStack(spacing: 10) {
                    Button {
                        copyAndOpenTerminal(command: Self.cliInstallCommand)
                        cliCopyConfirmed = true
                        settings.onboardingCLIDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            cliCopyConfirmed = false
                        }
                    } label: {
                        Label(cliCopyConfirmed ? "Copied ✓" : "Copy + open Terminal",
                              systemImage: cliCopyConfirmed ? "checkmark" : "terminal")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy CLI install command and open Terminal")
                    if cliDone && !cliCopyConfirmed {
                        Text("Re-run anytime to update.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var mcpCard: some View {
        card(number: 4, title: "Wire up the MCP server", required: false, done: mcpDone) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Lets Claude Desktop, Cursor, and any other MCP-compatible AI search your vault directly. Two steps — install the server, then paste the JSON snippet into your client's config.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("1. Install the server")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                codeBlock(Self.mcpInstallCommand)

                Text("2. Claude Desktop config snippet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                codeBlock(Self.mcpConfigSnippet)

                HStack(spacing: 10) {
                    Button {
                        copyAndOpenTerminal(command: Self.mcpInstallCommand)
                        mcpCopyConfirmed = true
                        settings.onboardingMCPDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            mcpCopyConfirmed = false
                        }
                    } label: {
                        Label(mcpCopyConfirmed ? "Copied ✓" : "Copy install + open Terminal",
                              systemImage: mcpCopyConfirmed ? "checkmark" : "terminal")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy MCP install command and open Terminal")
                    Button {
                        copyToClipboard(Self.mcpConfigSnippet)
                    } label: {
                        Label("Copy config snippet", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy the Claude Desktop config snippet to clipboard")
                    Spacer()
                }
                Link("Open Claude Desktop's MCP config docs →",
                     destination: URL(string: "https://modelcontextprotocol.io/quickstart/user")!)
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: - Footer disclosure card (always visible in the sheet too,
    // for parity with the always-visible card on the main ContentView
    // surface — the spec requires it everywhere the user could miss it).

    private var disclosureCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("Saving from Instagram or TikTok")
                    .font(.system(size: 12, weight: .medium))
                Text("These features use each platform's public web pages. Use may violate their terms of service and could lead to account restrictions on those platforms — Youty is a tool, you're responsible for your own use.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: - Footer (sticky CTA)

    private var footer: some View {
        HStack(spacing: 12) {
            Text(allDone ? "All set — happy saving."
                : requiredDone ? "Required step done. Optional items can wait."
                : "Pick a vault to continue.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(allDone ? "Done" : "Finish later") {
                settings.onboardingComplete = true
                onDismiss()
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            .disabled(!requiredDone)
            .accessibilityLabel(allDone ? "Done" : "Finish later")
            .accessibilityHint("Closes the onboarding sheet. You can reopen it from Settings → Onboarding.")
        }
    }

    // MARK: - Reusable card chrome

    @ViewBuilder
    private func card<Content: View>(number: Int,
                                     title: String,
                                     required: Bool,
                                     done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(done ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: 20, height: 20)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if required {
                    Text("REQUIRED")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            content()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .textSelection(.enabled)
        }
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Actions

    private func saveGeminiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainHelper.write(trimmed, account: "youty", service: "gemini-api")
            apiKeyStored = true
            apiKeyInput = ""
            apiKeyError = nil
        } catch {
            apiKeyError = "Couldn't store key: \(error.localizedDescription)"
        }
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func copyAndOpenTerminal(command: String) {
        copyToClipboard(command)
        // Open Terminal.app. We never inject the command — power users
        // want to see what they're running. Pasting is their move.
        if let terminalURL = URL(string: "file:///System/Applications/Utilities/Terminal.app") {
            NSWorkspace.shared.open(terminalURL)
        }
    }

    // MARK: - Canonical install copy (single source of truth)

    static let cliInstallCommand = "curl -sSfL https://raw.githubusercontent.com/legetdev/youty/main/Scripts/install-cli.sh | sh"

    static let mcpInstallCommand = "uv tool install youty-mcp"

    static let mcpConfigSnippet = """
{
  "mcpServers": {
    "youty": {
      "command": "youty-mcp"
    }
  }
}
"""
}
