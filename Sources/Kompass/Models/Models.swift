import Foundation
import SwiftUI

// Konvention für spätere Versionen: Neue Felder in gespeicherten Modellen immer als
// Optional hinzufügen, damit alte Datenstände weiterhin geladen werden können.
// (Ausnahme: `Preferences` wird tolerant dekodiert und darf Defaults haben.)

// MARK: - Semester

struct Term: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date
    /// Ende der Vorlesungszeit (danach meist Prüfungsphase).
    var lectureEnd: Date?

    func contains(_ date: Date) -> Bool { date >= start && date <= end.adding(days: 1) }

    /// Schlägt ein Semester passend zum Datum vor (deutsche Hochschulen: WiSe Okt–März, SoSe Apr–Sep).
    static func suggested(for date: Date = Date()) -> Term {
        let cal = Calendar.kompass
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
        if m >= 10 || m <= 3 {
            let startYear = m >= 10 ? y : y - 1
            let short = "\(startYear % 100)/\((startYear + 1) % 100)"
            return Term(name: "WiSe \(short)", start: d(startYear, 10, 1), end: d(startYear + 1, 3, 31), lectureEnd: d(startYear + 1, 2, 7))
        } else {
            return Term(name: "SoSe \(y % 100)", start: d(y, 4, 1), end: d(y, 9, 30), lectureEnd: d(y, 7, 20))
        }
    }
}

// MARK: - Farben

enum ModuleColor: String, Codable, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, brown, gray
    var id: String { rawValue }

    var color: Color { Color(platform: platformColor) }

    var platformColor: PlatformColor {
        switch self {
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .mint: return .systemMint
        case .teal: return .systemTeal
        case .cyan: return .systemCyan
        case .brown: return .systemBrown
        case .gray: return .systemGray
        }
    }

    var label: String {
        switch self {
        case .blue: return "Blau"
        case .indigo: return "Indigo"
        case .purple: return "Lila"
        case .pink: return "Pink"
        case .red: return "Rot"
        case .orange: return "Orange"
        case .yellow: return "Gelb"
        case .green: return "Grün"
        case .mint: return "Mint"
        case .teal: return "Petrol"
        case .cyan: return "Cyan"
        case .brown: return "Braun"
        case .gray: return "Grau"
        }
    }

    static func from(_ s: String?) -> ModuleColor? {
        guard let s = s?.lowercased() else { return nil }
        if let c = ModuleColor(rawValue: s) { return c }
        return ModuleColor.allCases.first { $0.label.lowercased() == s }
    }
}

// MARK: - Modul

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case vorlesung, uebung, tutorium, seminar, praktikum, sonstiges
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vorlesung: return "Vorlesung"
        case .uebung: return "Übung"
        case .tutorium: return "Tutorium"
        case .seminar: return "Seminar"
        case .praktikum: return "Praktikum"
        case .sonstiges: return "Sonstiges"
        }
    }
    var short: String {
        switch self {
        case .vorlesung: return "VL"
        case .uebung: return "Ü"
        case .tutorium: return "Tut"
        case .seminar: return "Sem"
        case .praktikum: return "Prak"
        case .sonstiges: return ""
        }
    }
    static func parse(_ s: String?) -> SessionKind {
        let s = (s ?? "").lowercased()
        if s.hasPrefix("vor") || s == "vl" || s.hasPrefix("lec") { return .vorlesung }
        if s.hasPrefix("üb") || s.hasPrefix("ueb") || s.hasPrefix("ex") { return .uebung }
        if s.hasPrefix("tut") { return .tutorium }
        if s.hasPrefix("sem") { return .seminar }
        if s.hasPrefix("prak") || s.hasPrefix("lab") { return .praktikum }
        return SessionKind(rawValue: s) ?? .sonstiges
    }
}

/// Wiederkehrender Veranstaltungstermin (Vorlesung, Übung …).
struct CourseSession: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: SessionKind = .vorlesung
    /// ISO-Wochentag: 1 = Montag … 7 = Sonntag
    var weekday: Int = 1
    var startMinutes: Int = 10 * 60
    var endMinutes: Int = 11 * 60 + 30
    var room: String = ""
    var biweekly: Bool = false
    var eventIdentifier: String?
    /// Geräteübergreifende Kennung (iCloud-UID) – die lokale Kennung unterscheidet sich je Gerät.
    var eventExternalID: String?

    var durationMinutes: Int { max(0, endMinutes - startMinutes) }
}

struct Topic: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    /// Selbsteinschätzung / Quiz-Ergebnis 0…1
    var confidence: Double = 0
    /// In der Vorlesung bereits behandelt
    var covered: Bool = false
    var lastReviewed: Date?

    static let levels: [(label: String, value: Double)] = [
        ("Neu", 0), ("Unsicher", 0.25), ("Geht so", 0.5), ("Sicher", 0.75), ("Beherrscht", 1)
    ]
    var levelIndex: Int { min(4, max(0, Int((confidence * 4).rounded()))) }
    var levelLabel: String { Topic.levels[levelIndex].label }
}

enum MaterialKind: String, Codable, CaseIterable, Identifiable {
    case vorlesung, uebung, loesung, altklausur, probeklausur, skript, zusammenfassung, notiz, sonstiges
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vorlesung: return "Vorlesung"
        case .uebung: return "Übung"
        case .loesung: return "Lösung"
        case .altklausur: return "Altklausur"
        case .probeklausur: return "Probeklausur"
        case .skript: return "Skript"
        case .zusammenfassung: return "Zusammenfassung"
        case .notiz: return "Notiz"
        case .sonstiges: return "Sonstiges"
        }
    }
    var plural: String {
        switch self {
        case .vorlesung: return "Vorlesungen"
        case .uebung: return "Übungen"
        case .loesung: return "Lösungen"
        case .altklausur: return "Altklausuren"
        case .probeklausur: return "Probeklausuren"
        case .skript: return "Skripte"
        case .zusammenfassung: return "Zusammenfassungen"
        case .notiz: return "Notizen"
        case .sonstiges: return "Sonstiges"
        }
    }
    var symbol: String {
        switch self {
        case .vorlesung: return "play.rectangle"
        case .uebung: return "pencil.and.list.clipboard"
        case .loesung: return "checkmark.rectangle"
        case .altklausur: return "doc.text.magnifyingglass"
        case .probeklausur: return "doc.badge.clock"
        case .skript: return "book.closed"
        case .zusammenfassung: return "text.append"
        case .notiz: return "note.text"
        case .sonstiges: return "doc"
        }
    }

    /// Rät die Art anhand des Dateinamens.
    static func guess(from fileName: String) -> MaterialKind {
        let n = fileName.lowercased()
        func has(_ parts: String...) -> Bool { parts.contains { n.contains($0) } }
        if has("lösung", "loesung", "solution", "musterl", "lsg") { return .loesung }
        if has("probeklausur", "probe-klausur", "mock", "practice exam", "übungsklausur") { return .probeklausur }
        if has("klausur", "exam", "prüfung", "pruefung") { return .altklausur }
        if has("übung", "uebung", "exercise", "blatt", "sheet", "aufgabe", "assignment", "tutorial", "homework") { return .uebung }
        if has("zusammenfassung", "summary", "cheat", "spickzettel", "formelsammlung") { return .zusammenfassung }
        if has("skript", "script", "lecture notes", "lecturenotes") { return .skript }
        if has("vorlesung", "lecture", "folien", "slides", "kapitel", "chapter", "vl", "lec") { return .vorlesung }
        if has(".md", ".txt") { return .notiz }
        return .sonstiges
    }

    static func parse(_ s: String?) -> MaterialKind? {
        guard let s = s?.lowercased() else { return nil }
        if let k = MaterialKind(rawValue: s) { return k }
        return MaterialKind.allCases.first { $0.label.lowercased() == s || $0.plural.lowercased() == s }
    }
}

enum MaterialStatus: String, Codable {
    case extracting, ready, empty, failed
}

struct Material: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var kind: MaterialKind
    /// Dateiname im Kompass-Materialordner
    var fileName: String
    var originalName: String
    var addedAt = Date()
    var status: MaterialStatus = .extracting
    var pageCount: Int?
    var charCount: Int = 0
    var studied: Bool = false
    var topicIDs: [UUID] = []
    var lectureNumber: Int?
    var usedOCR: Bool?

    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
}

struct Module: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var code: String = ""
    var color: ModuleColor = .blue
    var ects: Double = 5
    var termID: UUID?
    var lecturer: String = ""
    var notes: String = ""
    var weeklyGoalHours: Double = 6
    var sessions: [CourseSession] = []
    var topics: [Topic] = []
    var materials: [Material] = []
    var archived: Bool = false
    var createdAt = Date()
    var targetGrade: String?

    var displayCode: String { code.isEmpty ? String(name.prefix(3)).uppercased() : code }

    /// Faustregel: 1 ECTS ≈ 30 h Arbeit, davon grob die Hälfte Selbststudium über ~15 Wochen.
    static func suggestedWeeklyHours(ects: Double) -> Double {
        max(1, (ects * 30 / 15 * 0.6).rounded())
    }
}

// MARK: - Fristen & Aufgaben

enum DeadlineKind: String, Codable, CaseIterable, Identifiable {
    case klausur, abgabe, praesentation, testat, anmeldung, sonstiges
    var id: String { rawValue }
    var label: String {
        switch self {
        case .klausur: return "Klausur"
        case .abgabe: return "Abgabe"
        case .praesentation: return "Präsentation"
        case .testat: return "Testat"
        case .anmeldung: return "Anmeldung"
        case .sonstiges: return "Termin"
        }
    }
    var symbol: String {
        switch self {
        case .klausur: return "graduationcap.fill"
        case .abgabe: return "tray.and.arrow.up.fill"
        case .praesentation: return "rectangle.inset.filled.and.person.filled"
        case .testat: return "checkmark.seal.fill"
        case .anmeldung: return "signature"
        case .sonstiges: return "flag.fill"
        }
    }
    var tint: Color {
        switch self {
        case .klausur: return .red
        case .abgabe: return .orange
        case .praesentation: return .purple
        case .testat: return .teal
        case .anmeldung: return .blue
        case .sonstiges: return .gray
        }
    }
    /// Standard-Vorlaufzeiten für Erinnerungen in Minuten.
    var defaultOffsets: [Int] {
        let h = 60, d = 24 * 60
        switch self {
        case .klausur: return [14 * d, 7 * d, 3 * d, 1 * d]
        case .abgabe: return [3 * d, 1 * d, 3 * h]
        case .praesentation: return [7 * d, 2 * d, 1 * d]
        case .testat: return [3 * d, 1 * d]
        case .anmeldung: return [7 * d, 2 * d, 1 * d]
        case .sonstiges: return [1 * d]
        }
    }
    var defaultPrepHours: Double {
        switch self {
        case .klausur: return 25
        case .abgabe: return 5
        case .praesentation: return 6
        case .testat: return 3
        case .anmeldung: return 0
        case .sonstiges: return 0
        }
    }
    static func parse(_ s: String?) -> DeadlineKind {
        let s = (s ?? "").lowercased()
        if s.hasPrefix("klaus") || s.hasPrefix("exam") || s.hasPrefix("prüf") { return .klausur }
        if s.hasPrefix("abg") || s.hasPrefix("sub") || s.hasPrefix("deadline") { return .abgabe }
        if s.hasPrefix("präs") || s.hasPrefix("praes") || s.hasPrefix("pres") || s.hasPrefix("vortrag") { return .praesentation }
        if s.hasPrefix("test") { return .testat }
        if s.hasPrefix("anm") || s.hasPrefix("reg") { return .anmeldung }
        return DeadlineKind(rawValue: s) ?? .sonstiges
    }
}

struct Deadline: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var kind: DeadlineKind
    var moduleID: UUID?
    var date: Date
    var allDay: Bool = false
    /// Dauer (z. B. Klausurdauer) in Minuten, 0 = Zeitpunkt
    var durationMinutes: Int = 0
    var location: String = ""
    var notes: String = ""
    var done: Bool = false
    var doneAt: Date?
    var reminderOffsets: [Int] = []
    var prepHours: Double?
    var eventIdentifier: String?
    var reminderIdentifier: String?
    var eventExternalID: String?
    var reminderExternalID: String?
    var createdAt = Date()

    var effectivePrepHours: Double { prepHours ?? kind.defaultPrepHours }
}

struct TaskItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var moduleID: UUID?
    var due: Date?
    var estimateMinutes: Int = 30
    var done: Bool = false
    var doneAt: Date?
    var createdAt = Date()
    var notes: String = ""
}

// MARK: - Lernzeit & Planung

enum SessionSource: String, Codable { case timer, manual, block, ai }

/// Nur noch zum Einlesen alter Daten (vor der Zeiterfassung) – siehe `Worklog`.
struct StudySession: Identifiable, Codable, Hashable {
    var id = UUID()
    var moduleID: UUID
    var start: Date
    var minutes: Int
    var topicIDs: [UUID] = []
    var note: String = ""
    var source: SessionSource = .manual
}

struct WorkBlock: Identifiable, Codable, Hashable {
    var id = UUID()
    var weekday: Int = 2
    var startMinutes: Int = 9 * 60
    var endMinutes: Int = 17 * 60
    var label: String = "Werkstudent"
}

enum BlockStatus: String, Codable { case planned, done, partial, missed }

/// Ein vom Planer erzeugter Lernblock (liegt als Termin im Kompass-Kalender).
struct PlannedBlock: Identifiable, Codable, Hashable {
    var id = UUID()
    var moduleID: UUID
    var start: Date
    var end: Date
    var focus: String = ""
    var status: BlockStatus = .planned
    var eventIdentifier: String?
    var eventExternalID: String?

    var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

struct WeekReflection: Identifiable, Codable, Hashable {
    var id = UUID()
    var weekStart: Date
    var rating: Int?
    var note: String = ""
    var aiSummary: String?
}

// MARK: - Lernen

struct Flashcard: Identifiable, Codable, Hashable {
    var id = UUID()
    var moduleID: UUID
    var topic: String = ""
    var front: String
    var back: String
    var ease: Double = 2.5
    var intervalDays: Double = 0
    var reps: Int = 0
    var lapses: Int = 0
    var due: Date = Date()
    var createdAt = Date()

    var isMature: Bool { intervalDays >= 7 }

    /// SM-2-Variante. grade: 0 = Nochmal, 1 = Schwer, 2 = Gut, 3 = Einfach
    mutating func review(grade: Int, now: Date = Date()) {
        switch grade {
        case 0:
            lapses += 1
            reps = 0
            intervalDays = 0
            ease = max(1.3, ease - 0.2)
            due = now.addingTimeInterval(10 * 60)
        case 1:
            ease = max(1.3, ease - 0.15)
            intervalDays = reps == 0 ? 1 : max(1, intervalDays * 1.2)
            reps += 1
            due = now.addingTimeInterval(intervalDays * 86400)
        case 2:
            intervalDays = reps == 0 ? 1 : (reps == 1 ? 3 : intervalDays * ease)
            reps += 1
            due = now.addingTimeInterval(intervalDays * 86400)
        default:
            ease += 0.15
            intervalDays = reps == 0 ? 4 : intervalDays * ease * 1.3
            reps += 1
            due = now.addingTimeInterval(intervalDays * 86400)
        }
    }
}

enum QuestionType: String, Codable { case single, open }

struct QuizQuestion: Identifiable, Codable, Hashable {
    var id = UUID()
    var type: QuestionType
    var prompt: String
    var options: [String] = []
    var correctIndex: Int?
    var answer: String = ""
    var explanation: String = ""
    var topic: String = ""
}

struct QuizAttempt: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var score: Double
    var answered: Int
}

struct Quiz: Identifiable, Codable, Hashable {
    var id = UUID()
    var moduleID: UUID
    var title: String
    var createdAt = Date()
    var questions: [QuizQuestion]
    var attempts: [QuizAttempt] = []
    var sourceMaterialIDs: [UUID] = []

    var bestScore: Double? { attempts.map(\.score).max() }
    var lastScore: Double? { attempts.last?.score }
}

enum DocKind: String, Codable, CaseIterable, Identifiable {
    case zusammenfassung, probeklausur, lernplan, notiz, erklaerung, wochenfazit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .zusammenfassung: return "Zusammenfassung"
        case .probeklausur: return "Probeklausur"
        case .lernplan: return "Lernplan"
        case .notiz: return "Notiz"
        case .erklaerung: return "Erklärung"
        case .wochenfazit: return "Wochenfazit"
        }
    }
    var symbol: String {
        switch self {
        case .zusammenfassung: return "text.append"
        case .probeklausur: return "doc.badge.clock"
        case .lernplan: return "list.bullet.clipboard"
        case .notiz: return "note.text"
        case .erklaerung: return "lightbulb"
        case .wochenfazit: return "calendar.badge.checkmark"
        }
    }
    static func parse(_ s: String?) -> DocKind {
        let s = (s ?? "").lowercased()
        if s.hasPrefix("zus") || s.hasPrefix("sum") { return .zusammenfassung }
        if s.hasPrefix("probe") || s.hasPrefix("mock") || s.contains("klausur") || s.contains("exam") { return .probeklausur }
        if s.contains("plan") { return .lernplan }
        if s.hasPrefix("erkl") || s.hasPrefix("expl") { return .erklaerung }
        return DocKind(rawValue: s) ?? .notiz
    }
}

struct StudyDoc: Identifiable, Codable, Hashable {
    var id = UUID()
    var moduleID: UUID?
    var kind: DocKind
    var title: String
    var markdown: String
    var createdAt = Date()
    var sourceMaterialIDs: [UUID] = []
}

// MARK: - Einstellungen

struct Preferences: Codable, Equatable {
    var userName: String = ""
    var onboardingDone: Bool = false
    var currentTermID: UUID? = nil

    // Lernzeiten
    var studyDayStart: Int = 8 * 60
    var studyDayEnd: Int = 21 * 60
    var maxStudyMinutesPerDay: Int = 300
    var blockMinutes: Int = 90
    var minBlockMinutes: Int = 45
    var breakMinutes: Int = 15
    var bufferMinutes: Int = 15
    var studyOnWeekends: Bool = true
    var weekendMaxMinutes: Int = 180
    var protectedEvenings: Bool = false

    // Kalender
    var kompassCalendarID: String? = nil
    var reminderListID: String? = nil
    var workCalendarID: String? = nil
    /// Titel des Arbeitskalenders (geräteübergreifend; die ID ist pro Gerät verschieden)
    var workCalendarTitle: String? = nil
    var hiddenCalendarIDs: [String] = []
    var blockAlarmMinutes: Int = 5

    // Erinnerungen
    var notifyLocal: Bool = true
    var useRemindersApp: Bool = true
    var useCalendarAlarms: Bool = true
    var weeklyReviewEnabled: Bool = true
    var weeklyReviewHour: Int = 18
    var dailyBriefingEnabled: Bool = true
    var dailyBriefingMinutes: Int = 7 * 60 + 30

    // KI
    var aiModel: String = "deepseek-chat"
    var aiBaseURL: String = "https://api.deepseek.com"
    var aiTemperature: Double = 0.6
    var aiConfirmExternalEdits: Bool = true

    var lastReviewDismissedWeek: Date? = nil
    var defaultFocusMinutes: Int = 50

    // Zeiterfassung
    var workWeeklyLimitHours: Double = 20
    var workLimitLectureOnly: Bool = true
    var confirmReminderEnabled: Bool = true
    var confirmReminderMinutes: Int = 20 * 60

    init() {}

    /// Tolerantes Dekodieren: fehlende Schlüssel bekommen ihre Defaults.
    static func decodeTolerant(from object: Any?) -> Preferences {
        guard let dict = object as? [String: Any] else { return Preferences() }
        let enc = JSONCoding.encoder
        guard let defData = try? enc.encode(Preferences()),
              var base = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return Preferences() }
        base.merge(dict) { _, new in new }
        guard let merged = try? JSONSerialization.data(withJSONObject: base),
              let p = try? JSONCoding.decoder.decode(Preferences.self, from: merged) else { return Preferences() }
        return p
    }
}

// MARK: - Speicherformat

struct AppData: Codable {
    var version: Int = 2
    var terms: [Term] = []
    var modules: [Module] = []
    var deadlines: [Deadline] = []
    var tasks: [TaskItem] = []
    var worklogs: [Worklog] = []
    var timeCategories: [TimeCategory] = []
    var categoryRules: [CategoryRule] = []
    /// Termin-Vorkommen, die bewusst als „nicht wahrgenommen“ markiert wurden (Schlüssel → Beginn).
    var skipped: [String: Date] = [:]
    var workBlocks: [WorkBlock] = []
    var blocks: [PlannedBlock] = []
    var flashcards: [Flashcard] = []
    var quizzes: [Quiz] = []
    var docs: [StudyDoc] = []
    var reflections: [WeekReflection] = []
    var prefs = Preferences()

    init() {}

    /// Lädt robust: Ein defektes Element führt nicht zum Verlust aller Daten.
    static func load(from data: Data) throws -> AppData {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var out = AppData()
        out.version = raw["version"] as? Int ?? 1
        out.terms = decodeArray(raw["terms"])
        out.modules = decodeArray(raw["modules"])
        out.deadlines = decodeArray(raw["deadlines"])
        out.tasks = decodeArray(raw["tasks"])
        out.worklogs = decodeArray(raw["worklogs"])
        out.timeCategories = decodeArray(raw["timeCategories"])
        out.categoryRules = decodeArray(raw["categoryRules"])
        if let sk = raw["skipped"], let d = try? JSONSerialization.data(withJSONObject: sk),
           let map = try? JSONCoding.decoder.decode([String: Date].self, from: d) { out.skipped = map }
        // Migration: frühere Lerneinheiten (Version 1) → Zeitbuchungen
        let legacy: [StudySession] = decodeArray(raw["sessions"])
        out.worklogs += legacy.map { s in
            Worklog(kind: .module, moduleID: s.moduleID, activity: .lernen, start: s.start, minutes: s.minutes,
                    note: s.source == .block ? "" : s.note,
                    source: { switch s.source { case .timer: return .timer; case .manual: return .manual; case .block: return .block; case .ai: return .ai } }(),
                    blockID: s.source == .block ? UUID(uuidString: s.note) : nil)
        }
        out.workBlocks = decodeArray(raw["workBlocks"])
        out.blocks = decodeArray(raw["blocks"])
        out.flashcards = decodeArray(raw["flashcards"])
        out.quizzes = decodeArray(raw["quizzes"])
        out.docs = decodeArray(raw["docs"])
        out.reflections = decodeArray(raw["reflections"])
        out.prefs = Preferences.decodeTolerant(from: raw["prefs"])
        return out
    }

    private static func decodeArray<T: Decodable>(_ any: Any?) -> [T] {
        guard let arr = any as? [Any] else { return [] }
        return arr.compactMap { el in
            guard let d = try? JSONSerialization.data(withJSONObject: el) else { return nil }
            do { return try JSONCoding.decoder.decode(T.self, from: d) } catch {
                NSLog("Kompass: Element von \(T.self) konnte nicht geladen werden: \(error)")
                return nil
            }
        }
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
