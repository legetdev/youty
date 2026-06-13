import AppKit
import SwiftUI
import Combine

// NSStatusBar menu bar item — opt-in via Settings.
//
// Behavior:
//   • Tiny icon on the right side of the menu bar (uses an SF Symbol so it
//     respects the menu bar's render style automatically).
//   • Click → small popover with a clipboard-pre-filled paste field + Save
//     button. Hitting Save runs the entire fetch + write pipeline silently
//     in the background — the main app window doesn't get yanked forward.
//     The popover briefly flashes a "Sent ✓" confirmation, then auto-closes.
//   • Show/hide is governed by `SettingsStore.menuBarEnabled` (default off).
//
// "Background save" guarantee: when the user fires a save from the menu
// bar, `IngestionFunnel.ingest(..., source: "menubar")` skips its usual
// `NSApp.activate(...)` call. The save runs in process using the main
// app's already-attached WKWebView pipelines; the user's focus stays in
// whatever app they were in.

@MainActor
final class MenuBarController: ObservableObject {

    @Published var clipboardCandidate: String?
    @Published var pasted: String = ""
    @Published var saveStatus: SaveStatus = .idle

    enum SaveStatus { case idle, sent }

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var clipboardWatcher: Timer?
    private var lastClipboardCount: Int = -1
    private var sentResetTimer: DispatchWorkItem?
    private var indexStatusObserver: AnyCancellable?
    private var isIndexingNow: Bool = false

    func apply(showing: Bool) {
        if showing {
            install()
        } else {
            uninstall()
        }
    }

    // MARK: - Install / uninstall

    private func install() {
        if statusItem != nil { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item
        applyIcon(indexing: IndexStatusStore.shared.isAnyIndexing)
        startClipboardWatcher()
        // Observe IndexStatusStore so the status item gains a small accent
        // dot while any saved bundle is mid-index, and loses it once
        // everything settles back to idle.
        indexStatusObserver = IndexStatusStore.shared.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let indexing = IndexStatusStore.shared.isAnyIndexing
                if indexing != self.isIndexingNow {
                    self.applyIcon(indexing: indexing)
                }
            }
    }

    private func uninstall() {
        if let popover = popover, popover.isShown { popover.performClose(nil) }
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        clipboardWatcher?.invalidate()
        clipboardWatcher = nil
        indexStatusObserver?.cancel()
        indexStatusObserver = nil
    }

    // Swap the status item image between the plain Y mark and the
    // Y-with-progress-dot composite. The dot is drawn in the accent
    // color (non-template) so it survives the menu bar's template render
    // pipeline — the user gets a calm "still working" signal without any
    // animation or focus disruption.
    private func applyIcon(indexing: Bool) {
        isIndexingNow = indexing
        guard let button = statusItem?.button else { return }
        if indexing {
            button.image = Self.makeIndexingIcon()
            button.toolTip = "Youty — indexing in background"
        } else {
            let image = NSImage(named: "MenuBarY")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Youty"
        }
    }

    // Builds an 18×18 composite: the template Y mark plus a small
    // 5×5 accent dot in the bottom-right corner. Marked non-template so
    // the dot keeps its accent color in both light + dark menu bars.
    private static func makeIndexingIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let result = NSImage(size: size)
        result.lockFocus()
        // Base mark — render the template manually so we control color.
        if let base = NSImage(named: "MenuBarY") {
            base.isTemplate = true
            // Tint to the menu bar's text color so it reads correctly.
            let tinted = base.copy() as! NSImage
            tinted.lockFocus()
            NSColor.labelColor.set()
            let rect = NSRect(origin: .zero, size: tinted.size)
            rect.fill(using: .sourceIn)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(origin: .zero, size: size))
        }
        // Accent dot, bottom-right.
        NSColor.controlAccentColor.setFill()
        let dotRect = NSRect(x: size.width - 6, y: 0, width: 5, height: 5)
        NSBezierPath(ovalIn: dotRect).fill()
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        refreshFromClipboard()
        saveStatus = .idle
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 320, height: 150)
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(controller: self,
                                          onSave: { [weak self] urlString in
                                              self?.commitSave(urlString: urlString)
                                          },
                                          onOpenMainApp: { [weak self] in
                                              self?.popover?.performClose(nil)
                                              MainWindowKeeper.shared.reveal()
                                          })
        )
        popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func commitSave(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        IngestionFunnel.shared.ingest(urlString: trimmed, source: "menubar")
        // Flash "Sent ✓" for ~0.9 s, then close the popover. The save itself
        // continues running in the main app's pipeline; the user gets a
        // notification when the bundle lands on disk (see ContentView).
        withAnimation(.easeInOut(duration: 0.18)) {
            saveStatus = .sent
            pasted = ""
        }
        sentResetTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.popover?.performClose(nil)
            self.saveStatus = .idle
        }
        sentResetTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: - Clipboard watcher

    private func startClipboardWatcher() {
        clipboardWatcher?.invalidate()
        // Cheap heartbeat — only reads the pasteboard's changeCount, not
        // its contents, unless something new arrived.
        clipboardWatcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFromClipboard() }
        }
        refreshFromClipboard()
    }

    private func refreshFromClipboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        if count == lastClipboardCount { return }
        lastClipboardCount = count
        guard let raw = pb.string(forType: .string) else {
            clipboardCandidate = nil
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if YoutyShareURLClassifier.isSupported(trimmed) {
            clipboardCandidate = trimmed
            if pasted.isEmpty { pasted = trimmed }
        } else {
            clipboardCandidate = nil
        }
    }
}

// MARK: - Popover SwiftUI view

struct MenuBarPopoverView: View {
    @ObservedObject var controller: MenuBarController
    let onSave: (String) -> Void
    let onOpenMainApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if controller.saveStatus == .sent {
                sentConfirmation
            } else {
                pasteRow
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: 320, height: 150)
    }

    private var header: some View {
        HStack {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.tint)
            Text("Save to Youty")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: onOpenMainApp) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Youty")
            .accessibilityLabel("Open Youty main window")
        }
    }

    private var pasteRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Paste a YouTube, TikTok or Instagram URL", text: $controller.pasted)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { onSave(controller.pasted) }
                .accessibilityLabel("Video URL")
                .accessibilityHint("Paste a YouTube, Instagram, or TikTok post URL — save runs silently in the background")
            HStack(spacing: 8) {
                Button {
                    onSave(controller.pasted)
                } label: {
                    Label("Save to Vault", systemImage: "arrow.down.to.line")
                        .font(.system(size: 12, weight: .medium))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!YoutyShareURLClassifier.isSupported(controller.pasted.trimmingCharacters(in: .whitespacesAndNewlines)))
                .accessibilityLabel("Save URL to vault")
                if let candidate = controller.clipboardCandidate,
                   candidate != controller.pasted.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Button("Use clipboard") {
                        controller.pasted = candidate
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Use clipboard URL")
                    .accessibilityHint("Fill the field with the URL currently on your clipboard")
                }
            }
        }
    }

    private var sentConfirmation: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Sent to Youty")
                    .font(.system(size: 13, weight: .medium))
                Text("Saving in the background…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("⌘V to paste · ⏎ to save")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
