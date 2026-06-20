import SwiftUI
import AppKit

// First-launch onboarding (R.2). Four cards, completable in any order:
//   1. Pick a vault folder — required to save anything.
//   2. AI search — runs 100% on-device (no key, nothing to configure).
//   3. Install the `youty` command-line binary — copies the install
//      command + opens Terminal so the user can see what runs.
//   4. Connect your AI (MCP) — one command (`uvx youty-mcp@latest install`)
//      auto-wires every MCP client detected on the Mac; or pick a single
//      client (Claude Code, Codex, Gemini CLI, Claude Desktop, Cursor, …)
//      and copy its exact command / JSON snippet.
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

    @State private var cliCopyConfirmed: Bool = false
    @State private var mcpCopyConfirmed: Bool = false
    @State private var mcpAutoCopyConfirmed: Bool = false
    @State private var mcpClient: MCPClient = .claudeCode

    private var vaultDone: Bool { vault.vaultURL != nil }
    /// "Done" for CLI/MCP is heuristic — we can't detect whether the
    /// user actually pasted the command into their terminal. Storing a
    /// "user pressed the button" flag in AppStorage is enough signal to
    /// stop nagging them on subsequent launches.
    private var cliDone: Bool { settings.onboardingCLIDone }
    private var mcpDone: Bool { settings.onboardingMCPDone }
    // AI search is ready on-device without a key, so it doesn't gate "all set".
    private var allDone: Bool { vaultDone && cliDone && mcpDone }
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
                        aiSearchCard
                        mcpCard
                        cliCard

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
            Text("A few quick steps to get the most out of Youty. The vault is required; everything else is optional and reachable from Settings → Onboarding any time.")
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

    private var aiSearchCard: some View {
        // AI search runs 100% on-device — nothing to configure, so this card is
        // purely informational and reads as "done" by default.
        card(number: 2, title: "AI search — on-device", required: false, done: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Searching your saved videos by meaning runs 100% on-device — no API key, no account, nothing leaves your Mac. It works the moment you save your first video.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("Ready to go — nothing to set up.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var cliCard: some View {
        card(number: 4, title: "youty CLI (for developers)", required: false, done: cliDone) {
            VStack(alignment: .leading, spacing: 10) {
                Text("For developers and scripting. Save, list, and read transcripts from your terminal, or pipe JSON into your own tools. Its search is fast keyword matching over titles and tags — for meaning-based search, use the MCP above. The button copies the install command and opens Terminal so you can paste + run it.")
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
        card(number: 3, title: "Connect your AI assistant (MCP)", required: false, done: mcpDone) {
            VStack(alignment: .leading, spacing: 10) {
                Text("The main way to use Youty agentically — your AI searches everything you've saved by meaning, across transcripts and frames, then reads them straight into its context. Works with any MCP-capable client.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Primary path: one command auto-detects every MCP client on the
                // Mac and wires Youty into each. The sandboxed app can't edit other
                // apps' configs itself, so this runs the (non-sandboxed) youty-mcp
                // package's installer via uvx.
                Text("Wire every AI client on this Mac — one command:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                codeBlock(Self.mcpAutoInstallCommand)
                HStack(spacing: 10) {
                    Button {
                        copyAndOpenTerminal(command: Self.mcpAutoInstallCommand)
                        mcpAutoCopyConfirmed = true
                        settings.onboardingMCPDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            mcpAutoCopyConfirmed = false
                        }
                    } label: {
                        Label(mcpAutoCopyConfirmed ? "Copied ✓" : "Copy + open Terminal",
                              systemImage: mcpAutoCopyConfirmed ? "checkmark" : "terminal")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy the auto-install command and open Terminal")
                    Spacer()
                }
                Text("Detects Claude Code, Claude Desktop, Cursor, Codex, Gemini CLI and more, and adds Youty to each — preserving your other settings. Re-run anytime; it only touches Youty's own entry. Needs uv: brew install uv")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.4).padding(.vertical, 2)

                // Manual path: copy one client's exact config / command instead.
                Text("Or set up one client yourself")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Client")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("AI client", selection: $mcpClient) {
                        ForEach(MCPClient.allCases) { client in
                            Text(client.displayName).tag(client)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .accessibilityLabel("Choose your MCP client")
                    Spacer()
                }
                Text(mcpClient.instruction)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                codeBlock(mcpClient.snippet)
                HStack(spacing: 10) {
                    Button {
                        if mcpClient.isCLI {
                            copyAndOpenTerminal(command: mcpClient.snippet)
                        } else {
                            copyToClipboard(mcpClient.snippet)
                        }
                        mcpCopyConfirmed = true
                        settings.onboardingMCPDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            mcpCopyConfirmed = false
                        }
                    } label: {
                        Label(mcpCopyConfirmed ? "Copied ✓"
                                : mcpClient.isCLI ? "Copy + open Terminal" : "Copy config",
                              systemImage: mcpCopyConfirmed ? "checkmark"
                                : mcpClient.isCLI ? "terminal" : "doc.on.doc")
                    }
                    .controlSize(.small)
                    .accessibilityLabel(mcpClient.isCLI
                                        ? "Copy MCP command and open Terminal"
                                        : "Copy the MCP config snippet to clipboard")
                    Spacer()
                }

                Link("How to add an MCP server →",
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

    /// Canonical install path is the Homebrew tap (`legetdev/homebrew-youty`,
    /// scaffolded in `Scripts/homebrew/youty.rb`, published at R.6).
    /// `brew install <user>/<repo>/<formula>` auto-taps + installs in one
    /// command, so the user never has to know about the tap mechanic.
    static let cliInstallCommand = "brew install legetdev/youty/youty"

    // `uvx …@latest` fetches + runs the newest published youty-mcp on every
    // launch — so there's no separate install step and no manual upgrade ever:
    // a normal client restart always loads the latest server. The Mac app
    // (Sparkle) and CLI (brew) already auto-update; this keeps the MCP in step.
    static let mcpInstallCommand = "claude mcp add youty -- uvx youty-mcp@latest"

    // One-shot auto-wiring: the youty-mcp package's installer detects every MCP
    // client on the Mac and merges Youty into each config. `uvx …@latest install`
    // dispatches to youty_mcp.cli → install (bare `uvx …@latest` runs the server).
    static let mcpAutoInstallCommand = "uvx youty-mcp@latest install"

    static let mcpConfigSnippet = """
{
  "mcpServers": {
    "youty": {
      "command": "uvx",
      "args": ["youty-mcp@latest"]
    }
  }
}
"""
}

// The MCP clients surfaced in onboarding. CLI agents (Claude Code, Codex,
// Gemini CLI) are wired with a single `… mcp add` command; GUI/file clients
// (Claude Desktop, Cursor) take the JSON snippet pasted into a config file.
// Every path points at `uvx youty-mcp@latest`, so a normal client restart
// always loads the newest server — no manual upgrade. Commands verified against
// each tool's current docs (June 2026).
private enum MCPClient: String, CaseIterable, Identifiable {
    case claudeCode, codex, geminiCLI, claudeDesktop, cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .geminiCLI: return "Gemini CLI"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        }
    }

    /// CLI agents take a terminal command; the rest paste JSON into a config file.
    var isCLI: Bool {
        switch self {
        case .claudeCode, .codex, .geminiCLI: return true
        case .claudeDesktop, .cursor: return false
        }
    }

    var instruction: String {
        switch self {
        case .claudeCode, .codex, .geminiCLI:
            return "Run this in your terminal:"
        case .claudeDesktop:
            return "Paste into ~/Library/Application Support/Claude/claude_desktop_config.json, then restart Claude Desktop:"
        case .cursor:
            return "Paste into ~/.cursor/mcp.json (or .cursor/mcp.json in a project), then restart Cursor:"
        }
    }

    var snippet: String {
        switch self {
        case .claudeCode: return OnboardingView.mcpInstallCommand
        case .codex: return "codex mcp add youty -- uvx youty-mcp@latest"
        case .geminiCLI: return "gemini mcp add youty uvx youty-mcp@latest"
        case .claudeDesktop, .cursor: return OnboardingView.mcpConfigSnippet
        }
    }
}
