import Foundation
import Observation

/// Lernmaterial von Claude über das Claude-Abo (ohne API-Kosten).
///
/// Ablauf über Dateien im Datenordner (`Claude/…`, liegt mit in iCloud):
/// - Kompass legt Aufträge in `Auftraege/` ab („Mit Claude erstellen“).
/// - Ein geplanter Claude-Durchlauf (`Scripts/kompass_claude.py`) bearbeitet Aufträge und neue Materialien
///   und legt fertige Ergebnisse in `Eingang/`.
/// - Kompass übernimmt den Eingang (Karteikarten, Dokumente, Quizze, Themen) und löscht die Dateien.
/// - `status.json` schreibt nur das Skript (letzter Durchlauf, Zusammenfassung).
@MainActor
@Observable
final class ClaudeBridge {
    /// Ein Auftrag aus der App – Format wie in `kompass_claude.py` erwartet.
    struct Request: Codable, Identifiable {
        var version = 1
        var id = UUID()
        var createdAt = Date()
        var kind: String
        var moduleID: UUID
        var moduleName: String
        var materialIDs: [UUID]
        var count: Int?
        var difficulty: Int?
        var openShare: Double?
        var minutes: Int?
        var focus: String?

        var label: String { GeneratorKind(rawValue: kind)?.label ?? kind }
    }

    private(set) var pending: [Request] = []
    private(set) var lastRun: Date?
    private(set) var lastSummary: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let store: DataStore
    @ObservationIgnored private var timer: Timer?

    init(store: DataStore) {
        self.store = store
    }

    static var dir: URL { Paths.root.appendingPathComponent("Claude", isDirectory: true) }
    private static func folder(_ name: String) -> URL {
        let u = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static var requestsDir: URL { folder("Auftraege") }
    private static var inboxDir: URL { folder("Eingang") }
    private static var failedDir: URL { folder("Fehlerhaft") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func start() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        importDeliveries()
        pending = Self.jsonFiles(in: Self.requestsDir).compactMap { url in
            CoordinatedFile.read(url).flatMap { try? Self.decoder.decode(Request.self, from: $0) }
        }
        .sorted { $0.createdAt < $1.createdAt }
        loadStatus()
    }

    func pending(for moduleID: UUID) -> [Request] { pending.filter { $0.moduleID == moduleID } }

    // MARK: Aufträge

    func enqueue(_ kind: GeneratorKind, module: Module, materialIDs: [UUID], options: GeneratorOptions) {
        var r = Request(kind: kind.rawValue, moduleID: module.id, moduleName: module.name, materialIDs: materialIDs)
        switch kind {
        case .quiz: r.count = options.count; r.difficulty = options.difficulty; r.openShare = options.openShare
        case .flashcards: r.count = options.count
        case .mockExam: r.difficulty = options.difficulty; r.minutes = options.minutes
        default: break
        }
        r.focus = options.focus.trimmed.nilIfEmpty
        guard let data = try? Self.encoder.encode(r) else { return }
        CoordinatedFile.write(data, to: Self.requestsDir.appendingPathComponent("\(r.id.uuidString).json"))
        refresh()
    }

    func cancel(_ request: Request) {
        try? FileManager.default.removeItem(at: Self.requestsDir.appendingPathComponent("\(request.id.uuidString).json"))
        refresh()
    }

    // MARK: Ergebnisse übernehmen

    /// Ergebnisdatei von Claude (geschrieben und geprüft von `kompass_claude.py submit`).
    private struct Delivery: Decodable {
        struct Card: Decodable { var id: UUID; var topic: String?; var front: String; var back: String }
        struct Doc: Decodable { var id: UUID; var kind: String; var title: String; var markdown: String; var sourceMaterialIDs: [UUID]? }
        struct QuizDraft: Decodable { var id: UUID; var title: String; var questions: [QuizQuestion]; var sourceMaterialIDs: [UUID]? }
        struct TopicDraft: Decodable { var title: String; var covered: Bool? }
        var version: Int
        var id: UUID
        var title: String?
        var moduleID: UUID
        var flashcards: [Card]?
        var docs: [Doc]?
        var quizzes: [QuizDraft]?
        var topics: [TopicDraft]?
        /// Aufräumen: Karten, die Claude wieder entfernen soll (z. B. zu viele aus einem Auftrag)
        var removeFlashcardIDs: [UUID]?
    }

    private func importDeliveries() {
        var parts: [String] = []
        for url in Self.jsonFiles(in: Self.inboxDir) {
            guard let data = CoordinatedFile.read(url) else { continue } // iCloud lädt noch
            guard let d = try? Self.decoder.decode(Delivery.self, from: data) else {
                try? FileManager.default.moveItem(at: url, to: Self.failedDir.appendingPathComponent(url.lastPathComponent))
                continue
            }
            if store.module(d.moduleID) != nil, let summary = apply(d) { parts.append(summary) }
            try? FileManager.default.removeItem(at: url)
        }
        if !parts.isEmpty {
            app?.showToast("Claude: " + parts.joined(separator: " · "), symbol: "sparkles")
        }
    }

    /// Übernimmt eine Lieferung (doppelte Inhalte werden übersprungen). Liefert eine kurze Beschreibung.
    private func apply(_ d: Delivery) -> String? {
        var counts: [String] = []

        if let remove = d.removeFlashcardIDs.map(Set.init), !remove.isEmpty {
            let before = store.flashcards.count
            store.flashcards.removeAll { remove.contains($0.id) }
            if before > store.flashcards.count { counts.append("\(before - store.flashcards.count) Karten entfernt") }
        }

        let knownCards = Set(store.flashcards.map(\.id))
        let knownFronts = Set(store.flashcards.filter { $0.moduleID == d.moduleID }.map { $0.front.lowercased() })
        let cards = (d.flashcards ?? []).filter { !knownCards.contains($0.id) && !knownFronts.contains($0.front.lowercased()) }
            .map { Flashcard(id: $0.id, moduleID: d.moduleID, topic: $0.topic ?? "", front: $0.front, back: $0.back) }
        if !cards.isEmpty {
            store.flashcards.append(contentsOf: cards)
            counts.append("\(cards.count) Karteikarten")
        }

        for doc in d.docs ?? [] {
            let kind = DocKind(rawValue: doc.kind) ?? .notiz
            if let i = store.docs.firstIndex(where: { $0.id == doc.id }) {
                // Cheat Sheet & „Das musst du können“ werden laufend aktualisiert
                store.docs[i].title = doc.title
                store.docs[i].markdown = doc.markdown
                store.docs[i].kind = kind
                counts.append("\(kind.label) aktualisiert")
            } else {
                store.docs.append(StudyDoc(id: doc.id, moduleID: d.moduleID, kind: kind, title: doc.title,
                                           markdown: doc.markdown, sourceMaterialIDs: doc.sourceMaterialIDs ?? []))
                counts.append(kind.label)
            }
        }

        let knownQuizzes = Set(store.quizzes.map(\.id))
        for q in d.quizzes ?? [] where !knownQuizzes.contains(q.id) && !q.questions.isEmpty {
            store.quizzes.append(Quiz(id: q.id, moduleID: d.moduleID, title: q.title, questions: q.questions,
                                      sourceMaterialIDs: q.sourceMaterialIDs ?? []))
            counts.append("Quiz")
        }

        if let topics = d.topics, !topics.isEmpty {
            var added = 0
            store.updateModule(d.moduleID) { m in
                var have = Set(m.topics.map { $0.title.lowercased() })
                for t in topics {
                    let title = t.title.trimmed
                    guard !title.isEmpty, !have.contains(title.lowercased()) else { continue }
                    m.topics.append(Topic(title: title, covered: t.covered ?? false))
                    have.insert(title.lowercased())
                    added += 1
                }
            }
            if added > 0 { counts.append("\(added) Themen") }
        }
        return counts.isEmpty ? nil : counts.joined(separator: ", ")
    }

    // MARK: Status des Skripts

    private struct Status: Decodable { var lastRun: Date?; var lastSummary: String? }

    private func loadStatus() {
        let url = Self.dir.appendingPathComponent("status.json")
        guard let data = CoordinatedFile.read(url), let s = try? Self.decoder.decode(Status.self, from: data) else { return }
        lastRun = s.lastRun
        lastSummary = s.lastSummary
    }

    private static func jsonFiles(in dir: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for p in all where p.lastPathComponent.hasSuffix(".icloud") {
            // ausgelagerte iCloud-Datei („.name.json.icloud“) anfordern
            let real = dir.appendingPathComponent(String(p.lastPathComponent.dropFirst().dropLast(7)))
            try? FileManager.default.startDownloadingUbiquitousItem(at: real)
        }
        return all.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    }
}
