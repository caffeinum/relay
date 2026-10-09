import AppKit
import RelayCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainController!

    /// The window goes up here, before AppKit finishes launching: the frame
    /// doesn't wait on the rest of the launch sequence.
    func applicationWillFinishLaunching(_ n: Notification) {
        Launch.mark("willFinish")
        do {
            try Paths.ensure()
            let config = try Config.load()
            main = try controller(config)
        } catch {
            let a = NSAlert()
            a.messageText = "\(Brand.name) can't start"
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        Launch.mark("controller")
        main.showFirstFrame()
        Launch.mark("shown")
    }

    /// A missing token doesn't stop the cache from drawing: the window opens
    /// read from disk and says why it can't sync.
    private func controller(_ config: Config) throws -> MainController {
        let (name, ws) = try config.current()
        let store = try Store(path: Paths.database(name).path)
        Launch.mark("store")
        var sync: Sync?
        var problem: String?
        do {
            sync = Sync(store: store, slack: Slack(api: ws.api, token: try Config.token(name, ws), writes: ws.writes ?? false))
        } catch {
            problem = "\(error)"
            log("no sync: \(error)")
        }
        let m = MainController(config: config, workspace: name, store: store, sync: sync, appToken: Config.appToken(name, ws), syncProblem: problem)
        m.onSwitchWorkspace = { [weak self] w in self?.switchTo(w) }
        return m
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Launch.mark("didFinishLaunching")
        guard main != nil else { return }
        if !Launch.headless { NSApp.activate(ignoringOtherApps: true) }

        // Everything past the first frame waits a turn of the run loop, so
        // none of it is paid for before the window is on screen.
        DispatchQueue.main.async { [self] in
            let ms = Launch.firstFrame
            log(String(format: "first frame %.0fms after process start (%d messages shown)", ms, main.list.messages.count))
            if Launch.bench {
                print(String(format: "first_frame_ms=%.1f messages=%d conversations=%d  ", ms, main.list.messages.count, main.sidebar.conversations.count)
                      + Launch.marks.map { String(format: "%@=%.0f", $0.0, $0.1) }.joined(separator: " "))
                fflush(stdout)
                // Held open a moment so relayctl bench can see the window land.
                DispatchQueue.main.asyncAfter(deadline: .now() + (Brand.env("BENCH_HOLD") != nil ? 1.5 : 0)) { exit(0) }
            }
            buildMenu()
            if Brand.env("OFFLINE") == nil { main.start() }
            Script.run(main)
        }
    }

    /// ⌘K → Switch to: the config's current workspace changes and the
    /// window is rebuilt around that workspace's cache.
    func switchTo(_ name: String) {
        do {
            var config = try Config.load()
            config.workspace = name
            try config.save()
            let old = main
            old?.saveState()
            old?.live?.stop()
            main = try controller(config)
            old?.window.orderOut(nil)
            main.showFirstFrame()
            main.start()
        } catch {
            main.toast.show("\(error)", error: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { main?.saveState() }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    private func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(Brand.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(Brand.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        bar.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem()
        bar.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = bar
        NSApp.windowsMenu = win
    }
}
