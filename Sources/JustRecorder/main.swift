import AppKit

// JustRecorder is an accessory (menu-bar only) app: no dock icon, no main window.
let justrecorderDelegate = AppDelegate()
let application = NSApplication.shared
// Only one copy may own the capture permission and global shortcut at a time.
if let identifier = Bundle.main.bundleIdentifier,
   let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
       .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
    existing.activate(options: [.activateIgnoringOtherApps])
    exit(0)
}
application.appearance = nil
application.delegate = justrecorderDelegate
application.setActivationPolicy(.accessory)
application.run()
