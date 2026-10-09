import AppKit
import RelayCore

/// A debugging hook for driving the app without hands: RELAY_SCRIPT holds
/// steps separated by ";" — `wait 1.5`, `key j`, `key cmd-k`, `type eng`,
/// `snap /tmp/a.png`, `quit`. Keys go through the same router a real key
/// press does.
enum Script {
    static func run(_ main: MainController) {
        guard let s = Brand.env("SCRIPT") else { return }
        let steps = s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        next(steps[...], main)
    }

    private static func next(_ steps: ArraySlice<String>, _ main: MainController) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.05
        switch parts[0] {
        case "wait": delay = Double(arg) ?? 1
        case "key": press(arg, main.window)
        case "type": type(arg, main.window)
        case "snap": snap(main.window, to: arg)
        case "hover": main.list.hover(message: Int(arg).map { $0 < 0 ? main.list.messages.count + $0 : $0 })
        case "edit": if let i = Int(arg).map({ $0 < 0 ? main.list.messages.count + $0 : $0 }), main.list.messages.indices.contains(i) { print("script: edit", main.list.beginEdit(ts: main.list.messages[i].ts)) }
        case "unread": main.list.show(main.list.messages, mode: .open(unreadAfter: arg.isEmpty ? main.current?.lastRead : arg, restore: nil))
        case "scroll": main.list.table.enclosingScrollView.map { s in s.contentView.scroll(to: NSPoint(x: 0, y: s.contentView.bounds.minY + (Double(arg) ?? 0))); s.reflectScrolledClipView(s.contentView) }
        case "load": if let c = main.current, let ms = try? main.store.messages(c.id, limit: Int(arg) ?? 2000) { main.list.show(ms, mode: .open(unreadAfter: nil, restore: nil)) }
        case "confirm": if let i = Int(arg).map({ $0 < 0 ? main.list.messages.count + $0 : $0 }), main.list.messages.indices.contains(i) { main.list.confirmDelete(ts: main.list.messages[i].ts) }
        case "appearance": NSApp.appearance = NSAppearance(named: arg == "light" ? .aqua : .darkAqua)
        case "me": main.list.context.me = main.store.me; main.thread.context.me = main.store.me
        case "timing": print("script:", main.list.lastShowTiming)
        case "open": if let c = main.sidebar.allConversations.first(where: { $0.label == arg || $0.name == arg || $0.id == arg }) { main.open(c.id) } else { print("script: no conversation \(arg)") }
        case "thread": if let i = Int(arg).map({ $0 < 0 ? main.list.messages.count + $0 : $0 }), main.list.messages.indices.contains(i) { main.list.select(i); main.openThread() }
        case "select": if let i = Int(arg).map({ $0 < 0 ? main.focusedList.messages.count + $0 : $0 }) { main.focusedList.select(i) }
        case "focus": arg == "thread" ? main.threadComposer.focus() : arg == "list" ? { main.window.makeFirstResponder(nil) }() : main.composer.focus()
        case "run": if let id = CommandID(rawValue: arg) { main.run(id) } else { print("script: no command \(arg)") }
        case "palette": main.showPalette(query: arg)
        case "state": state(main, arg)
        case "quit": NSApp.terminate(nil)
        default: print("script: unknown step \(step)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next(rest, main) }
    }

    /// One line a test can grep: what's open, what the composers hold, the last toast.
    private static func state(_ main: MainController, _ label: String) {
        let pal = (main.overlay as? Palette)?.itemTitles.prefix(12).joined(separator: " | ") ?? ""
        let msgs = main.list.messages.suffix(3).map { "\($0.author): \($0.text)\($0.edited ? " (edited)" : "")\($0.local.map { " [\($0.kind.rawValue) \($0.state.rawValue)]" } ?? "")\($0.reactions.isEmpty ? "" : " " + $0.reactions.map { ":\($0.name):\($0.count)" }.joined(separator: ","))" }
        print("state \(label): current=\(main.current?.label ?? "-") thread=\(main.threadTS ?? "-") composer=\(main.composer.mrkdwn.debugDescription) threadComposer=\(main.threadComposer.mrkdwn.debugDescription) toast=\(main.toast.last ?? "-")")
        print("  last: \(msgs.joined(separator: " || "))")
        if !main.thread.messages.isEmpty { print("  thread: \(main.thread.messages.map { "\($0.author): \($0.text)" }.joined(separator: " || "))") }
        if !pal.isEmpty { print("  palette: \(pal)") }
        fflush(stdout)
    }

    static let codes: [String: UInt16] = ["esc": 53, "return": 36, "down": 125, "up": 126, "space": 49, "right": 124, "left": 123, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "tab": 48]

    private static func press(_ k: String, _ window: NSWindow) {
        var mods: NSEvent.ModifierFlags = []
        var key = k
        if key.hasPrefix("cmd-") { mods.insert(.command); key = String(key.dropFirst(4)) }
        if key.hasPrefix("ctrl-") { mods.insert(.control); key = String(key.dropFirst(5)) }
        let code = codes[key] ?? 0
        let named = ["return": "\r", "esc": "\u{1b}", "space": " ", "down": "\u{F701}", "up": "\u{F700}", "right": "\u{F703}", "left": "\u{F702}", "home": "\u{F729}", "end": "\u{F72B}", "pageup": "\u{F72C}", "pagedown": "\u{F72D}", "tab": "\t"]
        let chars = codes[key] != nil ? (named[key] ?? "") : key
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: chars,
                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
        if Launch.headless { window.sendEvent(e) } else { NSApp.sendEvent(e) }
    }

    /// Key presses, one per character, into whatever has focus: the same
    /// path real typing takes (key router, then the text view).
    private static func type(_ s: String, _ window: NSWindow) {
        for ch in s {
            let c = String(ch)
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: c,
                                           charactersIgnoringModifiers: c, isARepeat: false, keyCode: c == " " ? 49 : 0) else { continue }
            window.sendEvent(e)
        }
    }

    private static func snap(_ window: NSWindow, to path: String) {
        guard let v = window.contentView?.superview ?? window.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
