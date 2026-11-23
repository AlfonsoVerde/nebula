import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A copy of everything on the clipboard, to put it back on undo.
struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> PasteboardSnapshot {
        let items = (NSPasteboard.general.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
        return PasteboardSnapshot(items: items)
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let objects: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !objects.isEmpty { pb.writeObjects(objects) }
    }
}

/// ⌘Z for the last Nebula action. Right after an action ⌘Z is Nebula's for a few
/// seconds (then it goes back to the apps); the menu item works at any time.
@MainActor
final class UndoCenter {
    enum Action {
        case files([URL], restoring: PasteboardSnapshot?)        // created files → Trash
        case pasteboard(PasteboardSnapshot)                      // copied → previous clipboard
        case moves([(from: URL, to: URL)], created: [URL])       // grouped / renamed → back
        case replaced([(original: URL, backup: URL)])            // cleaned in place → original
        case expiry([URL])                                       // expiry set → removed
    }

    static let shared = UndoCenter()
    static let window: UInt64 = 10_000_000_000

    private(set) var pending: Action?
    private let hotKey = HotKey()
    private var expiry: Task<Void, Never>?

    var canUndo: Bool { pending != nil }

    private init() {
        hotKey.onPress = { [weak self] in self?.undo() }
    }

    func register(_ action: Action) {
        pending = action
        hotKey.register(Shortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey), key: "Z"))
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.window)
            guard !Task.isCancelled else { return }
            self?.hotKey.unregister()
        }
    }

    @discardableResult
    func undo() -> Bool {
        guard let action = pending else { return false }
        pending = nil
        expiry?.cancel()
        hotKey.unregister()
        switch action {
        case .files(let urls, let snapshot):
            for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            ClipboardHistory.shared.remove(files: urls)
            snapshot?.restore()
        case .pasteboard(let snapshot):
            snapshot.restore()
        case .moves(let moves, let created):
            let fm = FileManager.default
            for move in moves.reversed() { try? fm.moveItem(at: move.to, to: move.from) }
            for folder in created where ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["x"]).filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.removeItem(at: folder)
            }
        case .replaced(let pairs):
            for pair in pairs { _ = try? FileManager.default.replaceItemAt(pair.original, withItemAt: pair.backup) }
        case .expiry(let urls):
            ExpiryStore.shared.remove(urls)
        }
        Toast.show("Annullato", symbol: "arrow.uturn.backward")
        return true
    }
}

// MARK: - Toast

@MainActor
enum Toast {
    private static var panel: NebulaPanel?

    static func show(_ text: String, symbol: String) {
        panel?.orderOut(nil)
        let p = NSEvent.mouseLocation
        let size = NSSize(width: 180, height: 48)
        let panel = NebulaPanel(contentRect: NSRect(x: p.x - size.width / 2, y: p.y + 18, width: size.width, height: size.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.configure()
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        panel.orderFrontRegardless()
        self.panel = panel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if Self.panel === panel {
                panel.orderOut(nil)
                Self.panel = nil
            }
        }
    }
}

struct ToastView: View {
    let text: String
    let symbol: String
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6))
        .environment(\.colorScheme, .dark)
        .scaleEffect(shown ? 1 : 0.8)
        .opacity(shown ? 1 : 0)
        .frame(width: 180, height: 48)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { shown = true } }
    }
}
