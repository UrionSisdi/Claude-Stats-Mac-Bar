import Foundation

/// Parsed-jsonl cache: a file is re-parsed only when its size or mtime changes.
struct ScanCache: Codable {
    struct FileEntry: Codable {
        let size: Int
        let mtime: Double
        let records: [UsageRecord]
    }

    var version = 1
    var files: [String: FileEntry] = [:]

    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeStats", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("scan-cache.json")
    }()

    static func load() -> ScanCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ScanCache.self, from: data),
              cache.version == 1
        else { return ScanCache() }
        return cache
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
