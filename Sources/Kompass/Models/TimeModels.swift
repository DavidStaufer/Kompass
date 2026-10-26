import Foundation
import SwiftUI

// MARK: - Zeiterfassung (ähnlich Jira-Worklogs)

/// Wofür die Zeit gebucht wird.
enum TrackKind: String, Codable, CaseIterable {
    case module, work, custom
}

/// Art der Tätigkeit – erlaubt z. B. „nur Selbststudium“ vs. „Vorlesungen“ zu filtern.
enum ActivityKind: String, Codable, CaseIterable, Identifiable {
    case lernen, vorlesung, uebung, tutorium, seminar, praktikum, pruefung, arbeit, sonstiges
    var id: String { rawValue }

    var label: String {
        switch self {
        case .lernen: return "Selbststudium"
        case .vorlesung: return "Vorlesung"
        case .uebung: return "Übung"
        case .tutorium: return "Tutorium"
        case .seminar: return "Seminar"
        case .praktikum: return "Praktikum"
        case .pruefung: return "Prüfung"
        case .arbeit: return "Arbeit"
        case .sonstiges: return "Sonstiges"
        }
    }

    var symbol: String {
        switch self {
        case .lernen: return "brain.head.profile"
        case .vorlesung: return "building.columns"
        case .uebung: return "pencil.and.list.clipboard"
        case .tutorium: return "person.2"
        case .seminar: return "rectangle.inset.filled.and.person.filled"
        case .praktikum: return "flask"
        case .pruefung: return "graduationcap"
        case .arbeit: return "briefcase"
        case .sonstiges: return "tag"
        }
    }

    /// Zählt fürs Wochenziel (Selbststudium).
    var isSelfStudy: Bool { self == .lernen }
    /// Lehrveranstaltung (Vorlesung, Übung …).
    var isCourse: Bool { [.vorlesung, .uebung, .tutorium, .seminar, .praktikum].contains(self) }

    static func from(_ s: SessionKind) -> ActivityKind {
        switch s {
        case .vorlesung: return .vorlesung
        case .uebung: return .uebung
        case .tutorium: return .tutorium
        case .seminar: return .seminar
        case .praktikum: return .praktikum
        case .sonstiges: return .vorlesung
        }
    }

    static func defaultFor(_ kind: TrackKind) -> ActivityKind {
        switch kind {
        case .module: return .lernen
        case .work: return .arbeit
        case .custom: return .sonstiges
        }
    }

    static func parse(_ s: String?) -> ActivityKind? {
        guard let s = s?.lowercased(), !s.isEmpty else { return nil }
        if let a = ActivityKind(rawValue: s) { return a }
        if s.hasPrefix("lern") || s.hasPrefix("selbst") || s.hasPrefix("stud") { return .lernen }
        if s.hasPrefix("vor") { return .vorlesung }
        if s.hasPrefix("üb") || s.hasPrefix("ueb") { return .uebung }
        if s.hasPrefix("tut") { return .tutorium }
        if s.hasPrefix("sem") { return .seminar }
        if s.hasPrefix("prak") { return .praktikum }
        if s.hasPrefix("prüf") || s.hasPrefix("pruef") || s.hasPrefix("klaus") { return .pruefung }
        if s.hasPrefix("arb") || s.hasPrefix("work") { return .arbeit }
        return ActivityKind.allCases.first { $0.label.lowercased() == s }
    }
}

enum LogSource: String, Codable {
    case timer, manual, calendar, workBlock, block, ai

    var label: String {
        switch self {
        case .timer: return "Timer"
        case .manual: return "Manuell"
        case .calendar: return "Termin bestätigt"
        case .workBlock: return "Arbeitszeit bestätigt"
        case .block: return "Lernblock"
        case .ai: return "Assistent"
        }
    }
    var symbol: String {
        switch self {
        case .timer: return "timer"
        case .manual: return "pencil"
        case .calendar, .workBlock: return "calendar.badge.checkmark"
        case .block: return "checkmark.circle"
        case .ai: return "sparkles"
        }
    }
}

/// Eine Zeitbuchung („Worklog“).
struct Worklog: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: TrackKind
    var moduleID: UUID?
    var categoryID: UUID?
    var activity: ActivityKind
    var start: Date
    var minutes: Int
    var note: String = ""
    var title: String = ""
    var source: LogSource = .manual
    var taskID: UUID?
    var deadlineID: UUID?
    var blockID: UUID?
    /// Schlüssel des bestätigten Termin-Vorkommens (bei Serien inkl. Datum → nur diese Woche).
    var eventKey: String?
    var createdAt = Date()

    var end: Date { start.adding(minutes: minutes) }
}

/// Eigene Kategorie für „andere Sachen“ (Sport, Haushalt, Nebenprojekt …).
struct TimeCategory: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var color: ModuleColor = .teal
    var symbol: String = "tag"
    var archived: Bool = false
}

/// Gemerkte Zuordnung: gleichnamige Termine landen automatisch in derselben Kategorie.
struct CategoryRule: Identifiable, Codable, Hashable {
    var key: String
    var title: String
    var kind: TrackKind
    var moduleID: UUID?
    var categoryID: UUID?
    var activity: ActivityKind
    var id: String { key }

    static func normalize(_ title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }
}

/// Ziel einer Buchung bzw. des Timers.
struct TrackTarget: Hashable {
    var kind: TrackKind
    var moduleID: UUID?
    var categoryID: UUID?

    static let work = TrackTarget(kind: .work)
    static func module(_ id: UUID) -> TrackTarget { TrackTarget(kind: .module, moduleID: id) }
    static func custom(_ id: UUID) -> TrackTarget { TrackTarget(kind: .custom, categoryID: id) }

    /// Kompakter Schlüssel für Filter: „m:<id>“, „work“, „c:<id>“, „c:none“
    var key: String {
        switch kind {
        case .module: return "m:\(moduleID?.uuidString ?? "none")"
        case .work: return "work"
        case .custom: return "c:\(categoryID?.uuidString ?? "none")"
        }
    }

    init(kind: TrackKind, moduleID: UUID? = nil, categoryID: UUID? = nil) {
        self.kind = kind; self.moduleID = moduleID; self.categoryID = categoryID
    }

    init(_ w: Worklog) { self.init(kind: w.kind, moduleID: w.moduleID, categoryID: w.categoryID) }
}

/// Vorbelegung für den „Zeit buchen“-Dialog.
struct LogPreset: Hashable {
    var worklogID: UUID?
    var target: TrackTarget?
    var activity: ActivityKind?
    var taskID: UUID?
    var deadlineID: UUID?
    var start: Date?
    var minutes: Int?
    var title: String?
    /// Beim Bestätigen eines Termins mit abweichender Dauer
    var eventKey: String?
    var blockID: UUID?
    var source: LogSource?

    var idString: String {
        [worklogID?.uuidString, target?.key, taskID?.uuidString, deadlineID?.uuidString, start.map { "\(Int($0.timeIntervalSince1970))" }]
            .compactMap { $0 }.joined(separator: "-")
    }
}

// MARK: - Dauer im Jira-Format

extension Fmt {
    /// Parst Jira-artige Dauern: „1h 30m“, „90m“, „1,5h“, „2d“ (= 8 h), „1w“ (= 5 d), „1:30“.
    /// Ohne Einheit: „1,5“ und „2“ = Stunden, „45“ = Minuten.
    static func parseDuration(_ raw: String) -> Int? {
        var s = raw.lowercased().trimmed.replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            let p = s.split(separator: ":").map { Int(String($0).trimmed) }
            if p.count == 2, let h = p[0], let m = p[1] { return h * 60 + m }
            return nil
        }
        s = s.replacingOccurrences(of: "std.", with: "h").replacingOccurrences(of: "std", with: "h")
            .replacingOccurrences(of: "stunden", with: "h").replacingOccurrences(of: "stunde", with: "h")
            .replacingOccurrences(of: "min.", with: "m").replacingOccurrences(of: "minuten", with: "m").replacingOccurrences(of: "min", with: "m")
            .replacingOccurrences(of: "tage", with: "d").replacingOccurrences(of: "tag", with: "d")
            .replacingOccurrences(of: "wochen", with: "w").replacingOccurrences(of: "woche", with: "w")
        if let n = Double(s) {
            // Ohne Einheit: Dezimalzahlen und kleine Zahlen = Stunden („1,5“, „2“), sonst Minuten („45“, „90“)
            guard n > 0 else { return nil }
            if s.contains(".") || n <= 12 { return Int((n * 60).rounded()) }
            return Int(n.rounded())
        }
        let pattern = #"(\d+(?:\.\d+)?)\s*([wdhm])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        // Alles außer Zahlen/Einheiten/Leerzeichen → ungültig
        let rest = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "").trimmed
        guard rest.isEmpty else { return nil }
        var total = 0.0
        for m in matches {
            let v = Double(ns.substring(with: m.range(at: 1))) ?? 0
            switch ns.substring(with: m.range(at: 2)) {
            case "w": total += v * 5 * 8 * 60
            case "d": total += v * 8 * 60
            case "h": total += v * 60
            default: total += v
            }
        }
        let r = Int(total.rounded())
        return r > 0 ? r : nil
    }

    /// „1h 30m“
    static func jira(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m == 0 { return "0m" }
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r)m" }
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    /// Dezimalstunden wie im Stundenzettel: „1,5“
    static func decimalHours(_ minutes: Int) -> String {
        let h = Double(minutes) / 60
        if h == 0 { return "" }
        if h == h.rounded() { return "\(Int(h))" }
        return String(format: "%.1f", h).replacingOccurrences(of: ".", with: ",")
    }
}
