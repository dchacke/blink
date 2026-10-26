import AppKit

struct App {
    let name: String
    let url: URL
    let icon: NSImage
    // The localized name and, if different, the file name, so "System
    // Settings" is found under either name in other languages.
    let keys: [SearchKey]

    func match(_ query: SearchQuery) -> Match? {
        keys.compactMap { $0.match(query) }.max()
    }
}

/// The apps in the Applications folders, rescanned whenever they change, and
/// how often each was opened from Blink, for ranking.
final class AppIndex {
    private static let directories = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    private static let launchesKey = "launches"

    private(set) var apps: [App] = []
    private var launches = UserDefaults.standard.dictionary(forKey: launchesKey) as? [String: Int] ?? [:]
    private var stream: FSEventStreamRef?

    func start() {
        reload()
        watch()
    }

    func search(_ query: String, limit: Int) -> [App] {
        let query = SearchQuery(query)
        return apps
            .compactMap { app in app.match(query).map { (app, $0) } }
            .sorted { a, b in
                if a.1.tier != b.1.tier { return a.1.tier.rawValue > b.1.tier.rawValue }
                let launchesA = launches[a.0.url.path, default: 0], launchesB = launches[b.0.url.path, default: 0]
                if launchesA != launchesB { return launchesA > launchesB }
                if a.1.penalty != b.1.penalty { return a.1.penalty < b.1.penalty }
                return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
    }

    func recordLaunch(of app: App) {
        launches[app.url.path, default: 0] += 1
        UserDefaults.standard.set(launches, forKey: Self.launchesKey)
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            var apps: [App] = []
            for directory in Self.directories {
                Self.collect(URL(fileURLWithPath: directory), depth: 0, into: &apps)
            }
            DispatchQueue.main.async { self.apps = apps }
        }
    }

    // Descends into plain folders like Utilities, but not into app bundles.
    // Skips dotfiles only: Safari's symlink in /Applications is flagged hidden.
    private static func collect(_ directory: URL, depth: Int, into apps: inout [App]) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in entries where !url.lastPathComponent.hasPrefix(".") {
            if url.pathExtension == "app" {
                var name = FileManager.default.displayName(atPath: url.path)
                if name.hasSuffix(".app") { name.removeLast(4) }
                let fileName = url.deletingPathExtension().lastPathComponent
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 32, height: 32)
                let keys = name == fileName ? [SearchKey(name)] : [SearchKey(name), SearchKey(fileName)]
                apps.append(App(name: name, url: url, icon: icon, keys: keys))
            } else if depth < 2, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                collect(url, depth: depth + 1, into: &apps)
            }
        }
    }

    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<AppIndex>.fromOpaque(info!).takeUnretainedValue().reload()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, Self.directories as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
