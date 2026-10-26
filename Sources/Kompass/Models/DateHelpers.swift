import Foundation

extension Locale {
    static let de = Locale(identifier: "de_DE")
}

extension Calendar {
    static let kompass: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = .de
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.timeZone = .current
        return c
    }()
}

extension Date {
    var startOfDay: Date { Calendar.kompass.startOfDay(for: self) }
    var endOfDay: Date { startOfDay.adding(days: 1) }
    var startOfWeek: Date { Calendar.kompass.dateInterval(of: .weekOfYear, for: self)?.start ?? startOfDay }
    var startOfMonth: Date { Calendar.kompass.dateInterval(of: .month, for: self)?.start ?? startOfDay }

    func adding(days: Int) -> Date { Calendar.kompass.date(byAdding: .day, value: days, to: self) ?? self }
    func adding(weeks: Int) -> Date { Calendar.kompass.date(byAdding: .weekOfYear, value: weeks, to: self) ?? self }
    func adding(months: Int) -> Date { Calendar.kompass.date(byAdding: .month, value: months, to: self) ?? self }
    func adding(minutes: Int) -> Date { addingTimeInterval(Double(minutes) * 60) }

    /// ISO-Wochentag: 1 = Montag … 7 = Sonntag
    var isoWeekday: Int {
        let w = Calendar.kompass.component(.weekday, from: self)
        return ((w + 5) % 7) + 1
    }

    var minutesSinceMidnight: Int {
        let c = Calendar.kompass.dateComponents([.hour, .minute], from: self)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Uhrzeit (Minuten seit Mitternacht) an diesem Tag – sommerzeitsicher.
    func at(minutes: Int) -> Date {
        let day = startOfDay
        if minutes >= 24 * 60 { return day.adding(days: 1) }
        if minutes <= 0 { return day }
        return Calendar.kompass.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day.adding(minutes: minutes)
    }

    var weekNumber: Int { Calendar.kompass.component(.weekOfYear, from: self) }
    var isToday: Bool { Calendar.kompass.isDateInToday(self) }
    var isWeekend: Bool { isoWeekday >= 6 }
    func isSameDay(_ other: Date) -> Bool { Calendar.kompass.isDate(self, inSameDayAs: other) }

    /// Datum für ISO-Wochentag in der Woche dieses Datums.
    func dateForWeekday(_ iso: Int) -> Date { startOfWeek.adding(days: iso - 1) }

    func daysUntil(_ other: Date) -> Int {
        Calendar.kompass.dateComponents([.day], from: startOfDay, to: other.startOfDay).day ?? 0
    }
}

enum Fmt {
    static func time(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.de))
    }
    static func dayShort(_ d: Date) -> String {
        d.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).locale(.de))
    }
    static func dayLong(_ d: Date) -> String {
        d.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(.de))
    }
    static func dayMonth(_ d: Date) -> String {
        d.formatted(Date.FormatStyle().day().month(.abbreviated).locale(.de))
    }
    static func dateTime(_ d: Date, allDay: Bool = false) -> String {
        allDay ? dayShort(d) : "\(dayShort(d)), \(time(d))"
    }
    static func monthYear(_ d: Date) -> String {
        d.formatted(Date.FormatStyle().month(.wide).year().locale(.de))
    }
    static func weekday(_ iso: Int, short: Bool = false) -> String {
        let long = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
        let s = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        let i = min(7, max(1, iso)) - 1
        return short ? s[i] : long[i]
    }
    static func hm(_ minutes: Int) -> String {
        let m = max(0, minutes) % (24 * 60)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
    static func duration(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
    static func hours(_ minutes: Int) -> String {
        let h = Double(minutes) / 60
        if h == h.rounded() { return "\(Int(h)) h" }
        return String(format: "%.1f h", h).replacingOccurrences(of: ".", with: ",")
    }
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    /// „heute“, „morgen“, „in 5 Tagen“, „vor 2 Tagen“, „in 3 Std.“
    static func relative(_ d: Date, now: Date = Date()) -> String {
        let days = now.daysUntil(d)
        if days == 0 {
            let mins = Int(d.timeIntervalSince(now) / 60)
            if mins > 0 && mins < 60 { return "in \(mins) min" }
            if mins >= 60 { return "in \(mins / 60) Std." }
            if mins < 0 && mins > -60 { return "vor \(-mins) min" }
            return "heute"
        }
        if days == 1 { return "morgen" }
        if days == 2 { return "übermorgen" }
        if days == -1 { return "gestern" }
        if days > 0 {
            if days >= 21 { return "in \(days / 7) Wochen" }
            return "in \(days) Tagen"
        }
        return "vor \(-days) Tagen"
    }

    static func weekRange(_ weekStart: Date) -> String {
        let end = weekStart.adding(days: 6)
        return "\(dayMonth(weekStart)) – \(dayMonth(end))"
    }

    static func offsetLabel(_ minutes: Int) -> String {
        let d = 24 * 60
        if minutes % (7 * d) == 0 && minutes >= 7 * d { let w = minutes / (7 * d); return w == 1 ? "1 Woche" : "\(w) Wochen" }
        if minutes % d == 0 && minutes >= d { let n = minutes / d; return n == 1 ? "1 Tag" : "\(n) Tage" }
        if minutes % 60 == 0 && minutes >= 60 { let n = minutes / 60; return n == 1 ? "1 Std." : "\(n) Std." }
        return "\(minutes) min"
    }

    // Maschinenlesbare Daten für die KI
    static let machine: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
    static let machineDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func ai(_ d: Date, allDay: Bool = false) -> String {
        allDay ? machineDay.string(from: d) + " (\(weekday(d.isoWeekday, short: true)), ganztägig)"
               : machine.string(from: d) + " (\(weekday(d.isoWeekday, short: true)))"
    }

    /// Parst Datumsangaben der KI: ISO mit/ohne Zeit, mit/ohne Zeitzone.
    static func parse(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]).trimmingCharacters(in: .whitespaces) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "dd.MM.yyyy HH:mm", "dd.MM.yyyy"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func isDateOnly(_ raw: String?) -> Bool {
        guard let s = raw?.trimmingCharacters(in: .whitespaces) else { return false }
        return s.count == 10 && !s.contains("T") && !s.contains(":")
    }

    /// "14:30" → 870
    static func parseHM(_ raw: String?) -> Int? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 1, parts[0] >= 0, parts[0] <= 24 else { return nil }
        return parts[0] * 60 + (parts.count > 1 ? parts[1] : 0)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : self }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
