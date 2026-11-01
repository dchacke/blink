import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let index = AppIndex()
    private let files = FileIndex()
    private lazy var search = SearchController(index: index, files: files)
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        index.start()
        files.start()
        search.prepare()
        hotKey = HotKey(keyCode: kVK_Space, modifiers: cmdKey) { [weak self] in
            self?.search.toggle()
        }
        if hotKey == nil { NSLog("Blink: couldn't register ⌘Space") }
        registerLoginItemOnce()
    }

    // Only once, so turning it off in System Settings sticks.
    private func registerLoginItemOnce() {
        let key = "registeredLoginItem"
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        guard installed, !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Blink: couldn't add login item: \(error)")
        }
    }
}
