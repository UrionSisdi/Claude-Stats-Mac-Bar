import Foundation

struct TokenTotals: Codable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0

    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
    }
}

/// One assistant message with its token spend.
struct UsageRecord: Codable {
    let id: Int64
    let timestamp: Double
    let model: String
    let tokens: TokenTotals
}

struct PeriodStats {
    var tokens = TokenTotals()
    var cost: Double = 0
    var byModel: [(model: String, tokens: TokenTotals, cost: Double)] = []
    var messages = 0
}

enum LocalUsage {
    static let projectsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    // MARK: - Scanning

    /// Scans every `*.jsonl`, reusing the cache for files that did not change.
    static func scan(cache: inout ScanCache) -> [UsageRecord] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var seenPaths = Set<String>()
        var records: [UsageRecord] = []
        var seenIDs = Set<Int64>()

        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let path = url.path
            seenPaths.insert(path)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

            let fileRecords: [UsageRecord]
            if let cached = cache.files[path], cached.size == size, cached.mtime == mtime {
                fileRecords = cached.records
            } else {
                fileRecords = parseFile(url)
                cache.files[path] = ScanCache.FileEntry(size: size, mtime: mtime, records: fileRecords)
            }

            for record in fileRecords where seenIDs.insert(record.id).inserted {
                records.append(record)
            }
        }

        cache.files = cache.files.filter { seenPaths.contains($0.key) }
        records.sort { $0.timestamp < $1.timestamp }
        return records
    }

    private static func parseFile(_ url: URL) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var out: [UsageRecord] = []
        var seen = Set<Int64>()

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var lineStart = 0
            let count = raw.count
            for index in 0..<count where raw[index] == UInt8(ascii: "\n") {
                if index > lineStart {
                    appendRecord(from: Data(raw[lineStart..<index]), into: &out, seen: &seen)
                }
                lineStart = index + 1
            }
            if lineStart < count {
                appendRecord(from: Data(raw[lineStart..<count]), into: &out, seen: &seen)
            }
        }
        return out
    }

    private static func appendRecord(from line: Data, into out: inout [UsageRecord], seen: inout Set<Int64>) {
        // Cheap filter: only parse JSON for lines that carry a usage block.
        guard line.count > 40, contains(line, pattern: Array("\"usage\":{".utf8)) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String,
              !model.hasPrefix("<"),
              let usage = message["usage"] as? [String: Any]
        else { return }

        // The same usage block repeats for every content block of a message.
        let identifier = (message["id"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
        let hash = fnv1a(identifier)
        guard seen.insert(hash).inserted else { return }
        guard let timestamp = parseTimestamp(object["timestamp"] as? String) else { return }

        let creation = usage["cache_creation"] as? [String: Any]
        var tokens = TokenTotals(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite5m: creation?["ephemeral_5m_input_tokens"] as? Int ?? 0,
            cacheWrite1h: creation?["ephemeral_1h_input_tokens"] as? Int ?? 0)
        if creation == nil {
            tokens.cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0
        }
        guard tokens.total > 0 else { return }

        out.append(UsageRecord(id: hash, timestamp: timestamp, model: model, tokens: tokens))
    }

    private static func contains(_ data: Data, pattern: [UInt8]) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let count = raw.count
            let patternCount = pattern.count
            guard count >= patternCount else { return false }
            let first = pattern[0]
            for start in 0...(count - patternCount) where raw[start] == first {
                var matched = true
                for offset in 1..<patternCount where raw[start + offset] != pattern[offset] {
                    matched = false
                    break
                }
                if matched { return true }
            }
            return false
        }
    }

    private static func fnv1a(_ string: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash)
    }

    /// Parses `2026-08-10T10:59:50.911Z` without DateFormatter.
    static func parseTimestamp(_ string: String?) -> Double? {
        guard let string, string.count >= 19 else { return nil }
        let bytes = Array(string.utf8)
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }

        // Days since 1970-01-01, civil calendar (Howard Hinnant's algorithm).
        let shiftedYear = year - (month <= 2 ? 1 : 0)
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Double(days * 86_400 + hour * 3_600 + minute * 60 + second)
    }

    // MARK: - Aggregation

    static func stats(_ records: [UsageRecord], since: Double?) -> PeriodStats {
        var perModel: [String: TokenTotals] = [:]
        var result = PeriodStats()

        for record in records {
            if let since, record.timestamp < since { continue }
            perModel[record.model, default: TokenTotals()] += record.tokens
            result.tokens += record.tokens
            result.messages += 1
        }

        result.byModel = perModel
            .map { model, tokens in (model, tokens, Pricing.cost(tokens, model: model)) }
            .sorted { $0.2 > $1.2 }
        result.cost = result.byModel.reduce(0) { $0 + $1.2 }
        return result
    }

    /// Per-month breakdown in the local time zone, newest first.
    static func monthly(_ records: [UsageRecord], limit: Int) -> [(label: String, stats: PeriodStats)] {
        let calendar = Calendar.current
        var buckets: [Date: [UsageRecord]] = [:]
        for record in records {
            let date = Date(timeIntervalSince1970: record.timestamp)
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let start = calendar.date(from: components) else { continue }
            buckets[start, default: []].append(record)
        }

        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = "LLLL yyyy"

        return buckets.keys.sorted(by: >).prefix(limit).map { start in
            (formatter.string(from: start).capitalizedFirst, stats(buckets[start] ?? [], since: nil))
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
