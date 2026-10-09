import AppKit
import RelayCore

// Plain AppKit start: no scene graph to build before the first frame. The
// clock starts at the kernel's record of the process launch, not at main(),
// so dyld and static init count against the budget too.

enum Launch {
    static let processStart: Date = {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &kinfo, &size, nil, 0)
        let t = kinfo.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6)
    }()

    static var sinceStart: Double { Date().timeIntervalSince(processStart) * 1000 }
    static let bench = Brand.env("BENCH") != nil
    static let headless = Brand.env("HEADLESS") != nil
    static var marks: [(String, Double)] = []
    static var firstFrame: Double = 0
    static func mark(_ s: String) { if bench { marks.append((s, sinceStart)) } }
}

_ = Launch.processStart
Launch.mark("main")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// RELAY_HEADLESS: no Dock tile, no window on screen. Script snaps still
// render the window's views, so the UI can be checked without showing it.
app.setActivationPolicy(Launch.headless ? .prohibited : .regular)
app.run()
