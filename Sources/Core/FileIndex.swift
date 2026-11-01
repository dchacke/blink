import CoreServices
import Foundation
import UniformTypeIdentifiers

/// A file or folder that `FileIndex.search` found.
struct FoundFile {
    let name: String
    let path: String
    let match: Match
    let looksLikeHash: Bool
    fileprivate let entry: Int32
    fileprivate let generation: Int
}

/// The files and folders in the home folder, held in memory so a search goes
/// through millions of names in a few milliseconds instead of asking
/// Spotlight. Leaves out ~/Library, ~/Applications (app search covers those),
/// hidden files, node_modules and the insides of packages like .app or
/// .photoslibrary. Keeps up with changes through FSEvents, rereading only the
/// folders that changed.
final class FileIndex {
    private static let openedKey = "openedFiles"
    fileprivate static let rootParent: Int32 = -1
    fileprivate static let removed: Int32 = -2

    let root: String

    // Written on `queue` only, and only while holding `lock`, so `queue`
    // reads it freely and everyone else reads it under `lock`.
    private var storage = Storage()
    private var generation = 0
    private var openedPaths: [String: Int]
    private var openedEntries: [Int32: Int] = [:]
    private let lock = NSLock()

    private let queue = DispatchQueue(label: "Blink.FileIndex", qos: .utility)
    private var packageExtensions: [String: Bool] = [:]
    private var stream: FSEventStreamRef?

    init(root: String = NSHomeDirectory()) {
        self.root = (root as NSString).resolvingSymlinksInPath
        openedPaths = UserDefaults.standard.dictionary(forKey: Self.openedKey) as? [String: Int] ?? [:]
    }

    /// Indexes in the background, then follows changes.
    func start() {
        watch()
        queue.async { self.reload() }
    }

    /// How many files and folders are indexed.
    var count: Int {
        lock.withLock { storage.entries.count - storage.removedCount }
    }

    func search(_ query: String, limit: Int) -> [FoundFile] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty, limit > 0 else { return [] }
        return lock.withLock {
            var candidates = storage.candidates(q, limit: limit * 4)
            for (entry, _) in openedEntries {
                if let match = storage.match(entry, q) {
                    candidates.append(Candidate(match: match, entry: entry, looksLikeHash: storage.looksLikeHash(entry)))
                }
            }
            var seen = Set<Int32>()
            let ranked = candidates
                .filter { seen.insert($0.entry).inserted }
                .map { ($0, openedEntries[$0.entry, default: 0], storage.depth(of: $0.entry)) }
                .sorted { a, b in
                    if a.0.looksLikeHash != b.0.looksLikeHash { return !a.0.looksLikeHash }
                    if a.0.match.tier != b.0.match.tier { return a.0.match.tier.rawValue > b.0.match.tier.rawValue }
                    if a.1 != b.1 { return a.1 > b.1 }
                    if a.0.match.penalty != b.0.match.penalty { return a.0.match.penalty < b.0.match.penalty }
                    if a.2 != b.2 { return a.2 < b.2 }
                    return a.0.entry < b.0.entry
                }
            return ranked.prefix(limit).map { candidate, _, _ in
                FoundFile(
                    name: storage.name(of: candidate.entry),
                    path: root + "/" + storage.path(of: candidate.entry),
                    match: candidate.match,
                    looksLikeHash: candidate.looksLikeHash,
                    entry: candidate.entry,
                    generation: generation
                )
            }
        }
    }

    func recordOpen(_ file: FoundFile) {
        let opened = lock.withLock {
            openedPaths[file.path, default: 0] += 1
            if file.generation == generation { openedEntries[file.entry] = openedPaths[file.path] }
            return openedPaths
        }
        UserDefaults.standard.set(opened, forKey: Self.openedKey)
    }

    /// Reads the whole tree again. Runs on `queue`, or directly in tests.
    func reload() {
        var builder = Builder(firstEntry: 0, firstByte: 0)
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 {
            var existing: [[UInt8]: Int32] = [:]
            add(contentsOf: fd, parent: Self.rootParent, into: &builder, skipping: &existing)
        }
        let fresh = Storage(builder)
        let opened = lock.withLock { openedPaths }
        var entries: [Int32: Int] = [:]
        for (path, count) in opened {
            if let entry = fresh.locate(path, under: root, directory: false) { entries[entry] = count }
        }
        lock.withLock {
            storage = fresh
            openedEntries = entries
            generation += 1
        }
    }

    /// Rereads the given folders, adding what's new in them and removing
    /// what's gone. Runs on `queue`, or directly in tests.
    func refresh(_ paths: [String]) {
        let targets = Set(paths.compactMap { storage.locate($0, under: root, directory: true) })
        guard let lowest = targets.min() else { return }
        var children: [Int32: [[UInt8]: Int32]] = [:]
        for (i, entry) in storage.entries.buffer.enumerated()
        where entry.parent >= lowest && targets.contains(entry.parent) {
            children[entry.parent, default: [:]][Array(storage.nameBytes(of: Int32(i)))] = Int32(i)
        }

        var builder = Builder(firstEntry: storage.entries.count, firstByte: storage.names.count)
        var gone: [Int32] = []
        for target in targets {
            let path = target == Self.rootParent ? root : root + "/" + storage.path(of: target)
            var existing = children[target] ?? [:]
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            // A folder that's gone is removed by its parent's event.
            guard fd >= 0 else { continue }
            add(contentsOf: fd, parent: target, into: &builder, skipping: &existing)
            gone += existing.values
        }

        lock.withLock {
            storage.append(builder)
            storage.remove(gone)
        }
        if storage.removedCount > storage.entries.count / 2 { reload() }
    }

    // Adds what's in the directory open as `fd`, whose entry is `parent`, and
    // closes it. Names in `existing` are already indexed: they're taken out
    // of it instead, so what's left in it is gone.
    private func add(
        contentsOf fd: Int32, parent: Int32, into builder: inout Builder,
        skipping existing: inout [[UInt8]: Int32]
    ) {
        guard let dir = fdopendir(fd) else {
            close(fd)
            return
        }
        defer { closedir(dir) }
        let inRoot = parent == Self.rootParent
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            var type = entry.pointee.d_type
            withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                let name = UnsafeRawBufferPointer(rebasing: raw.prefix(length))
                let cName = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                // Also skips . and ..
                guard name.first != UInt8(ascii: ".") else { return }
                if type == DT_UNKNOWN {
                    var info = stat()
                    if fstatat(fd, cName, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR {
                        type = UInt8(DT_DIR)
                    }
                }
                let isDirectory = type == DT_DIR
                if isDirectory, Self.isExcluded(name, inRoot: inRoot) { return }
                if !existing.isEmpty, existing.removeValue(forKey: Array(name)) != nil { return }
                let index = builder.add(name, parent: parent)
                guard isDirectory, !isPackage(name) else { return }
                builder.directories[Storage.key(parent, name)] = index
                let child = openat(fd, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return }
                var none: [[UInt8]: Int32] = [:]
                add(contentsOf: child, parent: index, into: &builder, skipping: &none)
            }
        }
    }

    private static func isExcluded(_ name: UnsafeRawBufferPointer, inRoot: Bool) -> Bool {
        name.elementsEqual("node_modules".utf8)
            || inRoot && (name.elementsEqual("Library".utf8) || name.elementsEqual("Applications".utf8))
    }

    // Whether a folder is a package, which Finder shows as a single file.
    private func isPackage(_ name: UnsafeRawBufferPointer) -> Bool {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return false }
        let ext = String(decoding: name[(dot + 1)...], as: UTF8.self).lowercased()
        if let known = packageExtensions[ext] { return known }
        let isPackage = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        packageExtensions[ext] = isPackage
        return isPackage
    }

    private func watch() {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let index = Unmanaged<FileIndex>.fromOpaque(info!).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let mustRescan = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
            )
            if UnsafeBufferPointer(start: flags, count: count).contains(where: { $0 & mustRescan != 0 }) {
                index.reload()
            } else {
                index.refresh(paths)
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Whether a file name is mostly a hash or an ID like a UUID, which ranks
    /// below names people choose.
    static func looksLikeHash(_ name: String) -> Bool {
        Array(name.utf8).withUnsafeBufferPointer(looksLikeHash)
    }

    // Counts, in the name before its extension, hex runs (dashes allowed,
    // for UUIDs) that switch between digits and letters at least 3 times,
    // and runs of 16 or more letters and digits whose case and kind switch
    // every few characters, like base64. Plain numbers, like Bates numbers
    // and dates, and CamelCase words don't count.
    fileprivate static func looksLikeHash(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        var stem = name[...]
        if let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > 0 { stem = name[..<dot] }

        var total = 0, hex = 0, random = 0
        var hexRun = 0, hexSwitches = 0, lastHexWasDigit: Bool?
        var run = 0, runSwitches = 0, runDigits = 0, lastKind = 0
        func endHexRun() {
            if hexRun >= 8, hexSwitches >= 3 { hex += hexRun }
            hexRun = 0
            hexSwitches = 0
            lastHexWasDigit = nil
        }
        func endRun() {
            if run >= 16, runDigits >= 3, runSwitches * 2 >= run { random += run }
            run = 0
            runSwitches = 0
            runDigits = 0
            lastKind = 0
        }
        for b in stem {
            let isDigit = b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
            let isLower = b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")
            let isUpper = b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")
            let isHexLetter = (b | 0x20) >= UInt8(ascii: "a") && (b | 0x20) <= UInt8(ascii: "f")
            if isDigit || isHexLetter {
                if let last = lastHexWasDigit, last != isDigit { hexSwitches += 1 }
                lastHexWasDigit = isDigit
                hexRun += 1
            } else if b != UInt8(ascii: "-") {
                endHexRun()
            }
            if isDigit || isLower || isUpper {
                total += 1
                let kind = isDigit ? 1 : isLower ? 2 : 3
                if lastKind != 0, kind != lastKind { runSwitches += 1 }
                lastKind = kind
                if isDigit { runDigits += 1 }
                run += 1
            } else {
                endRun()
            }
        }
        endHexRun()
        endRun()
        return max(hex, random) * 2 > total
    }

    static func fold(_ string: String) -> [UInt8] {
        let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Array(folded.precomposedStringWithCanonicalMapping.utf8)
    }
}

private struct Candidate {
    let match: Match
    let entry: Int32
    let looksLikeHash: Bool

    func isBetter(than other: Candidate) -> Bool {
        if looksLikeHash != other.looksLikeHash { return !looksLikeHash }
        return match != other.match ? match > other.match : entry < other.entry
    }
}

// An entry's bytes in `names` are its name as is and then, unless it's ASCII,
// its name folded like the query. ASCII names are matched ignoring case
// instead, which saves storing them twice.
private struct Entry {
    var start: UInt32
    var count: UInt16
    var foldedCount: UInt16
    var parent: Int32
}

// Entries and names added since `firstEntry` and `firstByte`, kept apart
// until they're appended to the storage in one go.
private struct Builder {
    let firstEntry: Int
    let firstByte: Int
    var entries = MappedArray<Entry>()
    var names = MappedArray<UInt8>()
    var directories: [Int: Int32] = [:]

    mutating func add(_ name: UnsafeRawBufferPointer, parent: Int32) -> Int32 {
        let start = firstByte + names.count
        names.append(contentsOf: name)
        var foldedCount = 0
        if name.contains(where: { $0 >= 0x80 }) {
            let folded = FileIndex.fold(String(decoding: name, as: UTF8.self))
            folded.withUnsafeBytes { names.append(contentsOf: $0) }
            foldedCount = folded.count
        }
        entries.append(Entry(
            start: UInt32(start), count: UInt16(name.count),
            foldedCount: UInt16(foldedCount), parent: parent
        ))
        return Int32(firstEntry + entries.count - 1)
    }
}

// Parents always come before their children, so removing a folder takes one
// pass forward over the entries after it.
private struct Storage {
    var entries = MappedArray<Entry>()
    var names = MappedArray<UInt8>()
    // Folders by parent and name, to find the ones FSEvents reports.
    var directories: [Int: Int32] = [:]
    var removedCount = 0

    init() {}

    // Takes over a builder that started from nothing.
    init(_ builder: Builder) {
        entries = builder.entries
        names = builder.names
        directories = builder.directories
    }

    static func key(_ parent: Int32, _ name: UnsafeRawBufferPointer) -> Int {
        var hasher = Hasher()
        hasher.combine(parent)
        hasher.combine(bytes: name)
        return hasher.finalize()
    }

    mutating func append(_ builder: Builder) {
        entries.append(contentsOf: UnsafeRawBufferPointer(builder.entries.buffer))
        names.append(contentsOf: UnsafeRawBufferPointer(builder.names.buffer))
        directories.merge(builder.directories) { $1 }
    }

    mutating func remove(_ gone: [Int32]) {
        guard let first = gone.min() else { return }
        for i in gone { entries[Int(i)].parent = FileIndex.removed }
        var removed = gone.count
        for i in Int(first) + 1..<entries.count {
            let parent = entries[i].parent
            if parent >= 0, entries[Int(parent)].parent == FileIndex.removed {
                entries[i].parent = FileIndex.removed
                removed += 1
            }
        }
        removedCount += removed
    }

    func nameBytes(of entry: Int32) -> UnsafeBufferPointer<UInt8> {
        let e = entries[Int(entry)]
        return UnsafeBufferPointer(rebasing: names.buffer[Int(e.start)..<Int(e.start) + Int(e.count)])
    }

    func looksLikeHash(_ entry: Int32) -> Bool {
        FileIndex.looksLikeHash(nameBytes(of: entry))
    }

    func name(of entry: Int32) -> String {
        String(decoding: nameBytes(of: entry), as: UTF8.self)
    }

    // Relative to the root.
    func path(of entry: Int32) -> String {
        var components: [String] = []
        var i = entry
        while i >= 0 {
            components.append(name(of: i))
            i = entries[Int(i)].parent
        }
        return components.reversed().joined(separator: "/")
    }

    func depth(of entry: Int32) -> Int {
        var depth = 0, i = entries[Int(entry)].parent
        while i >= 0 {
            depth += 1
            i = entries[Int(i)].parent
        }
        return depth
    }

    // The entry at `path`, or the root's parent marker for the root itself.
    // Files take a pass over all entries; folders are looked up.
    func locate(_ path: String, under root: String, directory: Bool) -> Int32? {
        var path = Substring(path)
        if path.hasPrefix("/System/Volumes/Data/") { path = path.dropFirst("/System/Volumes/Data".count) }
        guard path.hasPrefix(root) else { return nil }
        path = path.dropFirst(root.count)
        guard path.isEmpty || path.first == "/" else { return nil }
        var components = path.split(separator: "/").map { Array($0.utf8) }
        let file = directory ? nil : components.popLast()
        var current = FileIndex.rootParent
        for component in components {
            let key = component.withUnsafeBytes { Self.key(current, $0) }
            guard let i = directories[key], entries[Int(i)].parent == current,
                  nameBytes(of: i).elementsEqual(component) else { return nil }
            current = i
        }
        guard let file else { return current }
        return entries.buffer.indices.first { i in
            entries[i].parent == current && nameBytes(of: Int32(i)).elementsEqual(file)
        }.map(Int32.init)
    }

    // The best `limit` matches, checking chunks of the entries in parallel.
    func candidates(_ q: [UInt8], limit: Int) -> [Candidate] {
        guard !entries.isEmpty else { return [] }
        let chunkCount = min(max(entries.count / 20_000, 1), ProcessInfo.processInfo.activeProcessorCount * 4)
        var results = [[Candidate]](repeating: [], count: chunkCount)
        let entries = entries.buffer, names = names.buffer
        q.withUnsafeBufferPointer { q in
            results.withUnsafeMutableBufferPointer { buffer in
                let results = buffer
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                    let lo = entries.count * chunk / chunkCount
                    let hi = entries.count * (chunk + 1) / chunkCount
                    results[chunk] = Self.candidates(q, in: entries, lo..<hi, names, limit: limit)
                }
            }
        }
        return results.flatMap { $0 }
    }

    // Looks for the query's first and last bytes 16 positions at a time,
    // across all the chunk's names at once, and fully matches only the
    // entries where both line up.
    private static func candidates(
        _ q: UnsafeBufferPointer<UInt8>, in entries: UnsafeBufferPointer<Entry>,
        _ range: Range<Int>, _ names: UnsafeBufferPointer<UInt8>, limit: Int
    ) -> [Candidate] {
        guard !range.isEmpty else { return [] }
        let n = q.count
        let startByte = Int(entries[range.lowerBound].start)
        let endByte = range.upperBound < entries.count ? Int(entries[range.upperBound].start) : names.count
        let lastStart = endByte - n + 1
        guard lastStart > startByte else { return [] }

        var top: [Candidate] = []
        var entry = range.lowerBound, checked = -1
        func check(_ position: Int) {
            while true {
                let e = entries[entry]
                if Int(e.start) + Int(e.count) + Int(e.foldedCount) > position { break }
                entry += 1
            }
            guard entry != checked else { return }
            checked = entry
            // Skip matching names that couldn't make the cut even as prefixes.
            if top.count == limit {
                let best = Match(tier: .prefix, penalty: max(Int(entries[entry].count) - n, 0))
                let bound = Candidate(match: best, entry: Int32(entry), looksLikeHash: false)
                guard bound.isBetter(than: top[limit - 1]) else { return }
            }
            guard let match = match(Int32(entry), q, entries, names) else { return }
            let e = entries[entry]
            let name = UnsafeBufferPointer(rebasing: names[Int(e.start)..<Int(e.start) + Int(e.count)])
            let candidate = Candidate(match: match, entry: Int32(entry), looksLikeHash: FileIndex.looksLikeHash(name))
            guard top.count < limit || candidate.isBetter(than: top[top.count - 1]) else { return }
            let at = top.firstIndex { candidate.isBetter(than: $0) } ?? top.count
            top.insert(candidate, at: at)
            if top.count > limit { top.removeLast() }
        }

        // Letters compare equal in either case once 0x20 is set on both.
        let first = q[0], last = q[n - 1]
        let firstCase: UInt8 = isLetter(first) ? 0x20 : 0, lastCase: UInt8 = isLetter(last) ? 0x20 : 0
        let firstBytes = SIMD16(repeating: first), lastBytes = SIMD16(repeating: last)
        let firstCases = SIMD16(repeating: firstCase), lastCases = SIMD16(repeating: lastCase)
        let base = UnsafeRawPointer(names.baseAddress!)
        var position = startByte
        while position + 16 <= lastStart {
            let a = base.loadUnaligned(fromByteOffset: position, as: SIMD16<UInt8>.self)
            let b = base.loadUnaligned(fromByteOffset: position + n - 1, as: SIMD16<UInt8>.self)
            let hits = ((a | firstCases) .== firstBytes) .& ((b | lastCases) .== lastBytes)
            if any(hits) {
                for lane in 0..<16 where hits[lane] { check(position + lane) }
            }
            position += 16
        }
        while position < lastStart {
            if names[position] | firstCase == first, names[position + n - 1] | lastCase == last {
                check(position)
            }
            position += 1
        }
        return top
    }

    func match(_ entry: Int32, _ q: [UInt8]) -> Match? {
        guard entries[Int(entry)].parent != FileIndex.removed else { return nil }
        return q.withUnsafeBufferPointer { Self.match(entry, $0, entries.buffer, names.buffer) }
    }

    // The best tier in which the query appears in the name as is or folded.
    private static func match(
        _ entry: Int32, _ query: UnsafeBufferPointer<UInt8>, _ entries: UnsafeBufferPointer<Entry>,
        _ names: UnsafeBufferPointer<UInt8>
    ) -> Match? {
        let e = entries[Int(entry)]
        guard e.parent != FileIndex.removed else { return nil }
        let n = query.count
        let start = Int(e.start), count = Int(e.count)
        var best: Match.Tier?
        for (from, length) in [(start, count), (start + count, Int(e.foldedCount))] where length >= n {
            for offset in 0...(length - n) {
                var equal = true
                for j in 0..<n where lowercased(names[from + offset + j]) != query[j] {
                    equal = false
                    break
                }
                guard equal else { continue }
                let tier: Match.Tier
                if offset == 0 {
                    tier = .prefix
                } else if isWordStart(names[from + offset - 1], names[from + offset]) {
                    tier = .wordPrefix
                } else {
                    tier = .substring
                }
                if best == nil || tier.rawValue > best!.rawValue { best = tier }
                if tier == .prefix { break }
            }
        }
        return best.map { Match(tier: $0, penalty: max(count - n, 0)) }
    }
}

/// An array of plain values in address space reserved up front, so it grows
/// without moving or copying, and only the pages it fills take memory.
/// Freeing it gives that memory straight back, where malloc would keep the
/// buffers a growing array leaves behind.
private final class MappedArray<Element> {
    // Far more than any home folder needs; unused address space is free.
    private static var capacity: Int { (1 << 32) / MemoryLayout<Element>.stride }

    private let base: UnsafeMutablePointer<Element>
    private(set) var count = 0

    init() {
        let bytes = Self.capacity * MemoryLayout<Element>.stride
        let address = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        precondition(address != MAP_FAILED, "couldn't reserve \(bytes) bytes")
        base = address!.bindMemory(to: Element.self, capacity: Self.capacity)
    }

    deinit {
        munmap(base, Self.capacity * MemoryLayout<Element>.stride)
    }

    var isEmpty: Bool { count == 0 }

    var buffer: UnsafeBufferPointer<Element> { UnsafeBufferPointer(start: base, count: count) }

    subscript(i: Int) -> Element {
        get { base[i] }
        set { base[i] = newValue }
    }

    func append(_ element: Element) {
        precondition(count < Self.capacity)
        base[count] = element
        count += 1
    }

    func append(contentsOf bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        let added = bytes.count / MemoryLayout<Element>.stride
        precondition(count + added <= Self.capacity)
        UnsafeMutableRawPointer(base + count).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        count += added
    }
}

private func isLetter(_ b: UInt8) -> Bool {
    b | 0x20 >= UInt8(ascii: "a") && b | 0x20 <= UInt8(ascii: "z")
}

private func lowercased(_ b: UInt8) -> UInt8 {
    b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") ? b | 0x20 : b
}

private func isWordStart(_ previous: UInt8, _ current: UInt8) -> Bool {
    func isAlphanumeric(_ b: UInt8) -> Bool {
        b >= 0x80 || isLetter(b) || b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
    }
    let startsWord = !isAlphanumeric(previous) && isAlphanumeric(current)
    let isLower = { (b: UInt8) in b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z") }
    let isUpper = { (b: UInt8) in b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") }
    return startsWord || isLower(previous) && isUpper(current)
}
