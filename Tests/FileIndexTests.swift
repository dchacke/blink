import Foundation
import Testing

@Suite struct FileIndexTests {
    let root: String
    let index: FileIndex

    init() throws {
        root = NSTemporaryDirectory() + "FileIndexTests-" + UUID().uuidString
        for path in [
            "Documents/Quarterly Report.pdf",
            "Documents/Work/report-draft.txt",
            "Documents/Über Notes.txt",
            "Documents/myReport.key",
            "Documents/.hidden.txt",
            "Documents/Thing.app/Contents/Info.plist",
            "Documents/Unrelated.txt",
            "Code/node_modules/report/index.js",
            "Library/report.plist",
            "Documents/report-9f86d081884c7d659a2feaa0c55ad015.json",
        ] {
            try Self.create(path, in: root)
        }
        index = FileIndex(root: root)
        index.reload()
    }

    private func create(_ path: String) throws {
        try Self.create(path, in: root)
    }

    private static func create(_ path: String, in root: String) throws {
        let url = URL(fileURLWithPath: root + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func names(_ query: String) -> [String] {
        index.search(query, limit: 8).map(\.name)
    }

    @Test(arguments: [
        ("report", "report-draft.txt", Match.Tier.prefix),
        ("REPORT", "report-draft.txt", .prefix),
        ("report", "Quarterly Report.pdf", .wordPrefix),
        ("report", "myReport.key", .wordPrefix),
        ("uarter", "Quarterly Report.pdf", .substring),
        ("uber", "Über Notes.txt", .prefix),
        ("über", "Über Notes.txt", .prefix),
        ("work", "Work", .prefix),
    ])
    func finds(query: String, name: String, tier: Match.Tier) throws {
        let found = try #require(index.search(query, limit: 8).first { $0.name == name })
        #expect(found.match.tier == tier)
    }

    @Test func ranksByTierWithHashNamesLast() {
        #expect(names("report") == [
            "report-draft.txt", "myReport.key", "Quarterly Report.pdf",
            "report-9f86d081884c7d659a2feaa0c55ad015.json",
        ])
    }

    @Test func givesFullPaths() throws {
        let found = try #require(index.search("draft", limit: 8).first)
        #expect(found.path == root + "/Documents/Work/report-draft.txt")
    }

    @Test func leavesOutHiddenFilesLibraryNodeModulesAndPackageContents() {
        #expect(names("hidden").isEmpty)
        #expect(names("plist").isEmpty)
        #expect(names("index.js").isEmpty)
        #expect(names("node_modules").isEmpty)
        #expect(names("thing") == ["Thing.app"])
    }

    @Test func picksUpAddedFiles() throws {
        try create("Documents/New/Budget.numbers.txt")
        try create("Budget.csv")
        index.refresh([root + "/Documents", root])
        #expect(Set(names("budget")) == ["Budget.csv", "Budget.numbers.txt"])
    }

    @Test func dropsRemovedFilesAndFolders() throws {
        try FileManager.default.removeItem(atPath: root + "/Documents/Work")
        try FileManager.default.removeItem(atPath: root + "/Documents/Unrelated.txt")
        index.refresh([root + "/Documents"])
        #expect(names("draft").isEmpty)
        #expect(names("work").isEmpty)
        #expect(names("unrelated").isEmpty)
        #expect(names("report") == [
            "myReport.key", "Quarterly Report.pdf", "report-9f86d081884c7d659a2feaa0c55ad015.json",
        ])
    }

    @Test(arguments: ["", "  ", "xyz", "reportx"])
    func findsNothing(query: String) {
        #expect(names(query).isEmpty)
    }
}

@Suite struct HashNameTests {
    @Test(arguments: [
        "2_dfea3958-bb40-48bc-bfa9-572dd76eedfd.changelog",
        "auto_join7-4-30d0c1a49784347fedbac21a69c3a899",
        "part-00551-e1ee791e-9651-4f91-9208-140ed8c2f5af-c000.snappy.parquet",
        "3f2a9c1d4e5b6a7f.json",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "hyNYr0H0tUxTF9r8HdxlYA==.apk",
    ])
    func flags(name: String) {
        #expect(FileIndex.looksLikeHash(name))
    }

    @Test(arguments: [
        "GOOG-CENG-00619959.tif",
        "CRWD-DELTA-000064981.jpg",
        "ConcatenatingMediaSource2.smali",
        "CardViewApi21Impl.smali",
        "AndroidCompositionLocals_androidKt$LocalConfiguration$1.smali",
        "2026-04-24_Google_Takedown_Claims.csv",
        "Quarterly Report.pdf",
        "Feedback2024.docx",
        "IMG_20230101_123456.jpg",
        "build-3f2a9c1d-and-a-much-longer-readable-name.log",
    ])
    func passes(name: String) {
        #expect(!FileIndex.looksLikeHash(name))
    }
}
