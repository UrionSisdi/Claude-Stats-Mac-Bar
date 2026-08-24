import Foundation

/// Reads the limit windows out of what `/usage` prints in the CLI.
///
/// Stripped of its escape codes, the screen says roughly this:
///
///     Current session
///     ▌ 1% used
///     Resets 7:10pm (Europe/Moscow)
///
///     Current week (all models)
///     █████ 10% used
///     Resets Aug 30 at 11pm (Europe/Moscow)
///
/// The CLI repaints that screen several times and a repaint may skip characters it believes
/// are already on screen, so headings arrive damaged ("Curr nt week") and line breaks are not
/// dependable. Parsing therefore anchors on "N% used" — the part that is either intact or
/// absent — and reads the window's identity from the text around it. A damaged block yields
/// nothing and the next repaint supplies it.
enum UsageText {
    private static let anchor = "([0-9]+(?:\\.[0-9]+)?)% used"

    /// How much text around the anchor belongs to the same block: the heading sits just
    /// above the bar and the reset just below, both well within this.
    private static let lookBehind = 140
    private static let lookAhead = 120

    static func snapshot(from text: String) -> UsageSnapshot? {
        guard let regex = try? NSRegularExpression(pattern: anchor) else { return nil }
        var snapshot = UsageSnapshot()

        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let percent = Double(text[valueRange]),
                  let matchRange = Range(match.range, in: text)
            else { continue }

            let before = text[bounded(text, from: matchRange.lowerBound, back: lookBehind)
                ..< matchRange.lowerBound]
            let after = text[matchRange.upperBound
                ..< bounded(text, from: matchRange.upperBound, forward: lookAhead)]

            guard let scope = scope(before: String(before)) else { continue }
            let window = UsageWindow(
                kind: scope.kind,
                model: scope.model,
                percent: percent,
                resetsAt: parseReset(String(after)))
            guard !snapshot.windows.contains(where: { $0.id == window.id }) else { continue }
            snapshot.windows.append(window)
        }

        return snapshot.windows.isEmpty ? nil : snapshot
    }

    // MARK: - Which window a percentage belongs to

    /// The heading right before the bar: "Current session", "Current week (all models)",
    /// or "Current week (Opus)". Only the distinguishing word has to survive intact.
    private static func scope(before: String) -> (kind: UsageWindow.Kind, model: String?)? {
        let session = before.range(of: "session", options: [.backwards, .caseInsensitive])
        let week = before.range(of: "week", options: [.backwards, .caseInsensitive])

        switch (session, week) {
        case let (session?, week?):
            // Both words are in range; the nearer one owns this bar.
            return session.lowerBound > week.lowerBound
                ? (.session, nil)
                : (.weekly, model(after: week.upperBound, in: before))
        case (_?, nil):
            return (.session, nil)
        case let (nil, week?):
            return (.weekly, model(after: week.upperBound, in: before))
        case (nil, nil):
            return nil
        }
    }

    /// The scope in brackets after "week", if any: "(Opus)" → "Opus", "(all models)" → nil.
    private static func model(after index: String.Index, in text: String) -> String? {
        let tail = String(text[index...])
        guard let name = tail.firstMatch("^[^(\n]{0,24}\\(([^)]{1,32})\\)")?[1] else { return nil }
        return name.lowercased().contains("all model") ? nil : name
    }

    // MARK: - Reset time

    /// "Resets 7:10pm (Europe/Moscow)" or "Resets Aug 30 at 11pm (Europe/Moscow)".
    static func parseReset(_ text: String) -> Date? {
        guard let resets = text.range(of: "Resets") else { return nil }
        let line = String(text[resets.lowerBound...].prefix(60))

        var calendar = Calendar(identifier: .gregorian)
        if let name = line.firstMatch("\\(([A-Za-z_]+/[A-Za-z_]+)\\)")?[1],
           let zone = TimeZone(identifier: name)
        {
            calendar.timeZone = zone
        }
        let now = Date()

        if let match = line.firstMatch(
            "Resets ([A-Za-z]{3}) ([0-9]{1,2}) at ([0-9]{1,2})(?::([0-9]{2}))?(am|pm)"),
            let month = month(match[1])
        {
            var components = DateComponents()
            components.year = calendar.component(.year, from: now)
            components.month = month
            components.day = Int(match[2] ?? "")
            components.hour = hour24(match[3], meridiem: match[5])
            components.minute = Int(match[4] ?? "0")
            guard let date = calendar.date(from: components) else { return nil }
            // The year is never printed, so a December window read in January is next year's.
            if date.timeIntervalSince(now) < -30 * 86_400 {
                return calendar.date(byAdding: .year, value: 1, to: date)
            }
            return date
        }

        guard let match = line.firstMatch("Resets ([0-9]{1,2})(?::([0-9]{2}))?(am|pm)") else {
            return nil
        }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour24(match[1], meridiem: match[3])
        components.minute = Int(match[2] ?? "0")
        guard let date = calendar.date(from: components) else { return nil }
        // A bare clock time that has already passed today belongs to tomorrow.
        return date > now ? date : calendar.date(byAdding: .day, value: 1, to: date)
    }

    private static func hour24(_ raw: String?, meridiem: String?) -> Int? {
        guard let raw, let hour = Int(raw) else { return nil }
        let base = hour % 12
        return meridiem?.lowercased() == "pm" ? base + 12 : base
    }

    private static func month(_ name: String?) -> Int? {
        guard let name else { return nil }
        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        return months.firstIndex(of: name.lowercased()).map { $0 + 1 }
    }

    // MARK: - Index arithmetic

    private static func bounded(_ text: String, from index: String.Index, back count: Int)
        -> String.Index
    {
        text.index(index, offsetBy: -count, limitedBy: text.startIndex) ?? text.startIndex
    }

    private static func bounded(_ text: String, from index: String.Index, forward count: Int)
        -> String.Index
    {
        text.index(index, offsetBy: count, limitedBy: text.endIndex) ?? text.endIndex
    }
}

/// Capture groups of one regex match; index 0 is the whole match, and a group that did
/// not participate reads as nil rather than trapping.
struct RegexMatch {
    private let groups: [String?]

    init(groups: [String?]) { self.groups = groups }

    subscript(index: Int) -> String? {
        groups.indices.contains(index) ? groups[index] : nil
    }
}

extension String {
    func firstMatch(_ pattern: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }

        let groups = (0..<match.numberOfRanges).map { index -> String? in
            Range(match.range(at: index), in: self).map { String(self[$0]) }
        }
        return RegexMatch(groups: groups)
    }
}
