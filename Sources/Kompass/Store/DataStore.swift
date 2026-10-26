import Foundation
import SwiftUI
import Observation

enum Paths {
    /// Demo-/Testmodus: `Kompass -kompass.dataDir /pfad -kompass.demo YES` nutzt einen eigenen Datenordner
    /// und fragt keine Berechtigungen an.
    static let isDemo = UserDefaults.standard.bool(forKey: "kompass.demo")

    /// Aktueller Datenordner (lokal oder iCloud Drive).
    static var root: URL { StorageLocation.shared.root }
    static var dataFile: URL { root.appendingPathComponent("kompass.json") }
    static var chatsFile: URL { root.appendingPathComponent("chats.json") }
    static var backups: URL {
        let u = root.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func materialsDir(_ moduleID: UUID) -> URL {
        let u = root.appendingPathComponent("Materialien", isDirectory: true).appendingPathComponent(moduleID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func materialFile(_ moduleID: UUID, _ m: Material) -> URL { materialsDir(moduleID).appendingPathComponent(m.fileName) }
    static func textFile(_ moduleID: UUID, _ materialID: UUID) -> URL { materialsDir(moduleID).appendingPathComponent("\(materialID.uuidString).txt") }
}

@MainActor
@Observable
final class DataStore {
    var terms: [Term] = [] { didSet { scheduleSave() } }
    var modules: [Module] = [] { didSet { scheduleSave() } }
    var deadlines: [Deadline] = [] { didSet { scheduleSave(); deadlinesChanged?() } }
    var tasks: [TaskItem] = [] { didSet { scheduleSave() } }
    var worklogs: [Worklog] = [] { didSet { scheduleSave(); worklogsChanged?() } }
    var timeCategories: [TimeCategory] = [] { didSet { scheduleSave() } }
    var categoryRules: [CategoryRule] = [] { didSet { scheduleSave() } }
    var skipped: [String: Date] = [:] { didSet { scheduleSave() } }
    var workBlocks: [WorkBlock] = [] { didSet { scheduleSave() } }
    var blocks: [PlannedBlock] = [] { didSet { scheduleSave() } }
    var flashcards: [Flashcard] = [] { didSet { scheduleSave() } }
    var quizzes: [Quiz] = [] { didSet { scheduleSave() } }
    var docs: [StudyDoc] = [] { didSet { scheduleSave() } }
    var reflections: [WeekReflection] = [] { didSet { scheduleSave() } }
    var prefs = Preferences() { didSet { if prefs != oldValue { persistDevicePrefs(); scheduleSave(); prefsChanged?(oldValue) } } }

    /// Wird nach Änderungen an Fristen aufgerufen (Erinnerungen neu planen).
    @ObservationIgnored var deadlinesChanged: (() -> Void)?
    @ObservationIgnored var prefsChanged: ((Preferences) -> Void)?
    @ObservationIgnored var worklogsChanged: (() -> Void)?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var textCache: [UUID: String] = [:]
    /// Zuletzt gelesener/geschriebener Stand (für die Zusammenführung mit dem anderen Gerät).
    @ObservationIgnored private var baseJSON: [String: Any] = [:]
    @ObservationIgnored private var lastModDate: Date?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored var reloaded: (() -> Void)?
    var loadError: String?
    /// Zeitpunkt der letzten Übernahme von Änderungen eines anderen Geräts.
    var lastRemoteSync: Date?

    init() {
        load()
        startPolling()
    }

    // MARK: Laden & Speichern

    private func load() {
        let url = Paths.dataFile
        guard CoordinatedFile.exists(url) else { baseJSON = [:]; lastModDate = nil; return }
        guard let data = CoordinatedFile.read(url) else {
            loadError = "Die Daten konnten nicht gelesen werden (iCloud noch nicht geladen?). Kompass versucht es gleich erneut."
            return
        }
        do {
            let d = try AppData.load(from: data)
            apply(d)
            baseJSON = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            lastModDate = CoordinatedFile.modificationDate(url)
            loadError = nil
        } catch {
            loadError = "Die Daten konnten nicht gelesen werden (\(error.localizedDescription)). Eine Sicherung liegt im Ordner „Backups“."
            let broken = Paths.root.appendingPathComponent("kompass-defekt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: broken)
        }
    }

    /// Übernimmt einen Datenstand, ohne Speichern auszulösen.
    private func apply(_ d: AppData) {
        loading = true
        defer { loading = false }
        terms = d.terms
        modules = d.modules
        deadlines = d.deadlines
        tasks = d.tasks
        worklogs = d.worklogs
        timeCategories = d.timeCategories
        categoryRules = d.categoryRules
        skipped = d.skipped
        workBlocks = d.workBlocks
        blocks = d.blocks
        flashcards = d.flashcards
        quizzes = d.quizzes
        docs = d.docs
        reflections = d.reflections
        var p = d.prefs
        restoreDevicePrefs(&p)
        prefs = p
        textCache.removeAll()
    }

    // MARK: Geräteabhängige Einstellungen
    // Kalender-IDs sind pro Gerät verschieden und werden deshalb nicht über iCloud geteilt.

    static let devicePrefKeys = ["kompassCalendarID", "reminderListID", "workCalendarID", "hiddenCalendarIDs"]

    private func persistDevicePrefs() {
        let d = UserDefaults.standard
        d.set(prefs.kompassCalendarID, forKey: "device.kompassCalendarID")
        d.set(prefs.reminderListID, forKey: "device.reminderListID")
        d.set(prefs.workCalendarID, forKey: "device.workCalendarID")
        d.set(prefs.hiddenCalendarIDs, forKey: "device.hiddenCalendarIDs")
        d.set(true, forKey: "device.prefsInitialized")
    }

    private func restoreDevicePrefs(_ p: inout Preferences) {
        let d = UserDefaults.standard
        guard d.bool(forKey: "device.prefsInitialized") else { return } // erster Start: Werte aus der Datei übernehmen
        p.kompassCalendarID = d.string(forKey: "device.kompassCalendarID")
        p.reminderListID = d.string(forKey: "device.reminderListID")
        p.workCalendarID = d.string(forKey: "device.workCalendarID")
        p.hiddenCalendarIDs = d.stringArray(forKey: "device.hiddenCalendarIDs") ?? []
    }

    /// Nach einem Wechsel des Speicherorts alles neu laden.
    func reloadFromDisk() {
        saveTask?.cancel()
        load()
        reloaded?()
    }

    // MARK: Synchronisierung über iCloud Drive

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForRemoteChanges() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// Prüft, ob ein anderes Gerät die Daten geändert hat, und führt sie zusammen.
    func checkForRemoteChanges() {
        guard StorageLocation.shared.mode == .iCloud || Paths.isDemo else { return }
        let url = Paths.dataFile
        guard let mod = CoordinatedFile.modificationDate(url), mod != lastModDate else { return }
        if saveTask != nil {
            saveNow() // führt beim Speichern zusammen
            return
        }
        guard let data = CoordinatedFile.read(url),
              let remote = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let local = currentJSON()
        let merged = DataMerge.merge(base: baseJSON, local: local, remote: remote)
        if let mergedData = try? JSONSerialization.data(withJSONObject: merged), let d = try? AppData.load(from: mergedData) {
            apply(d)
            reloaded?()
        }
        baseJSON = remote
        lastModDate = mod
        lastRemoteSync = Date()
        // Hatte das lokale Gerät eigene, noch nicht gespeicherte Änderungen, landen sie beim nächsten Speichern.
        if !DataMerge.equal(merged as NSDictionary, remote as NSDictionary) { scheduleSave() }
    }

    private func currentJSON() -> [String: Any] {
        guard let data = try? JSONCoding.encoder.encode(snapshot),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    var snapshot: AppData {
        var d = AppData()
        d.terms = terms
        d.modules = modules
        d.deadlines = deadlines
        d.tasks = tasks
        d.worklogs = worklogs
        d.timeCategories = timeCategories
        d.categoryRules = categoryRules
        d.skipped = skipped
        d.workBlocks = workBlocks
        d.blocks = blocks
        d.flashcards = flashcards
        d.quizzes = quizzes
        d.docs = docs
        d.reflections = reflections
        d.prefs = prefs
        return d
    }

    private func scheduleSave() {
        guard !loading else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    var hasPendingSave: Bool { saveTask != nil }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let url = Paths.dataFile
        var local = currentJSON()
        // Hat ein anderes Gerät inzwischen gespeichert? Dann erst zusammenführen.
        if let mod = CoordinatedFile.modificationDate(url), mod != lastModDate,
           let data = CoordinatedFile.read(url),
           let remote = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            local = DataMerge.merge(base: baseJSON, local: local, remote: remote)
            if let mergedData = try? JSONSerialization.data(withJSONObject: local), let d = try? AppData.load(from: mergedData) {
                apply(d)
                reloaded?()
            }
            lastRemoteSync = Date()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: local, options: [.prettyPrinted, .sortedKeys]) else { return }
        if CoordinatedFile.write(data, to: url) {
            baseJSON = local
            lastModDate = CoordinatedFile.modificationDate(url)
            backupIfNeeded(data)
        } else {
            NSLog("Kompass: Speichern fehlgeschlagen")
        }
    }

    /// Eine Sicherung pro Tag, die letzten 30 werden behalten.
    private func backupIfNeeded(_ data: Data) {
        let name = "kompass-\(Fmt.machineDay.string(from: Date())).json"
        let url = Paths.backups.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            let files = (try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: nil)) ?? []
            let sorted = files.filter { $0.lastPathComponent.hasPrefix("kompass-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in sorted.dropFirst(30) { try? FileManager.default.removeItem(at: old) }
        }
    }

    // MARK: Semester

    var currentTerm: Term? {
        if let id = prefs.currentTermID, let t = terms.first(where: { $0.id == id }) { return t }
        return terms.first(where: { $0.contains(Date()) }) ?? terms.sorted { $0.start > $1.start }.first
    }

    func term(_ id: UUID?) -> Term? { terms.first { $0.id == id } }

    // MARK: Module

    /// Module des aktuellen Semesters (bzw. ohne Semester), nicht archiviert.
    var activeModules: [Module] {
        let tid = currentTerm?.id
        return modules.filter { !$0.archived && ($0.termID == nil || $0.termID == tid) }
    }

    func module(_ id: UUID?) -> Module? {
        guard let id else { return nil }
        return modules.first { $0.id == id }
    }

    func moduleIndex(_ id: UUID) -> Int? { modules.firstIndex { $0.id == id } }

    func updateModule(_ id: UUID, _ change: (inout Module) -> Void) {
        guard let i = moduleIndex(id) else { return }
        var m = modules[i]
        change(&m)
        modules[i] = m
    }

    func moduleBinding(_ id: UUID) -> Binding<Module> {
        Binding(
            get: { self.module(id) ?? Module(name: "") },
            set: { new in if let i = self.moduleIndex(id) { self.modules[i] = new } }
        )
    }

    /// Findet ein Modul per ID, Kürzel oder Namen (für die KI).
    func findModule(_ ref: String?) -> Module? {
        guard let ref = ref?.trimmed, !ref.isEmpty else { return nil }
        if let id = UUID(uuidString: ref), let m = module(id) { return m }
        let l = ref.lowercased()
        return modules.first { $0.code.lowercased() == l || $0.name.lowercased() == l }
            ?? modules.first { $0.name.lowercased().contains(l) || l.contains($0.name.lowercased()) }
    }

    func color(for moduleID: UUID?) -> Color { module(moduleID)?.color.color ?? .accentColor }

    func nextExam(for moduleID: UUID, after date: Date = Date()) -> Deadline? {
        deadlines.filter { $0.moduleID == moduleID && $0.kind == .klausur && !$0.done && $0.date >= date.startOfDay }
            .sorted { $0.date < $1.date }.first
    }

    func deleteModule(_ id: UUID) {
        modules.removeAll { $0.id == id }
        flashcards.removeAll { $0.moduleID == id }
        quizzes.removeAll { $0.moduleID == id }
        docs.removeAll { $0.moduleID == id }
        worklogs.removeAll { $0.kind == .module && $0.moduleID == id }
        categoryRules.removeAll { $0.moduleID == id }
        blocks.removeAll { $0.moduleID == id }
        for i in deadlines.indices where deadlines[i].moduleID == id { deadlines[i].moduleID = nil }
        for i in tasks.indices where tasks[i].moduleID == id { tasks[i].moduleID = nil }
        try? FileManager.default.removeItem(at: Paths.materialsDir(id))
    }

    // MARK: Materialien

    func material(_ id: UUID) -> (module: Module, material: Material)? {
        for m in modules { if let mat = m.materials.first(where: { $0.id == id }) { return (m, mat) } }
        return nil
    }

    func text(of materialID: UUID) -> String {
        if let t = textCache[materialID] { return t }
        guard let (m, _) = material(materialID) else { return "" }
        let t = CoordinatedFile.read(Paths.textFile(m.id, materialID)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        textCache[materialID] = t
        return t
    }

    func setText(_ text: String, for materialID: UUID, moduleID: UUID) {
        textCache[materialID] = text
        try? text.write(to: Paths.textFile(moduleID, materialID), atomically: true, encoding: .utf8)
    }

    func updateMaterial(_ id: UUID, _ change: (inout Material) -> Void) {
        for mi in modules.indices {
            if let ti = modules[mi].materials.firstIndex(where: { $0.id == id }) {
                var m = modules[mi]
                change(&m.materials[ti])
                modules[mi] = m
                return
            }
        }
    }

    func deleteMaterial(_ id: UUID) {
        guard let (m, mat) = material(id) else { return }
        try? FileManager.default.removeItem(at: Paths.materialFile(m.id, mat))
        try? FileManager.default.removeItem(at: Paths.textFile(m.id, id))
        textCache[id] = nil
        updateModule(m.id) { $0.materials.removeAll { $0.id == id } }
    }

    // MARK: Fristen

    func deadline(_ id: UUID?) -> Deadline? { deadlines.first { $0.id == id } }

    func updateDeadline(_ id: UUID, _ change: (inout Deadline) -> Void) {
        guard let i = deadlines.firstIndex(where: { $0.id == id }) else { return }
        var d = deadlines[i]
        change(&d)
        deadlines[i] = d
    }

    var upcomingDeadlines: [Deadline] {
        deadlines.filter { !$0.done }.sorted { $0.date < $1.date }
    }

    var urgentDeadlineCount: Int {
        let limit = Date().adding(days: 7)
        return deadlines.filter { !$0.done && $0.date <= limit }.count
    }

    // MARK: Aufgaben

    func updateTask(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var t = tasks[i]
        change(&t)
        tasks[i] = t
    }

    func toggleTask(_ id: UUID) {
        updateTask(id) { t in
            t.done.toggle()
            t.doneAt = t.done ? Date() : nil
        }
    }

    // MARK: Lernzeit & Zeiterfassung

    /// Selbststudium in Minuten (zählt fürs Wochenziel).
    func minutes(moduleID: UUID? = nil, from: Date, to: Date) -> Int {
        worklogs.filter { w in
            w.kind == .module && w.activity.isSelfStudy && (moduleID == nil || w.moduleID == moduleID) && w.start >= from && w.start < to
        }.reduce(0) { $0 + $1.minutes }
    }

    /// Alle gebuchten Minuten, optional gefiltert.
    func loggedMinutes(from: Date, to: Date, where include: (Worklog) -> Bool = { _ in true }) -> Int {
        worklogs.filter { $0.start >= from && $0.start < to && include($0) }.reduce(0) { $0 + $1.minutes }
    }

    @discardableResult
    func logWork(_ target: TrackTarget, activity: ActivityKind? = nil, start: Date, minutes: Int, source: LogSource,
                 note: String = "", title: String = "", taskID: UUID? = nil, deadlineID: UUID? = nil,
                 blockID: UUID? = nil, eventKey: String? = nil) -> Worklog? {
        guard minutes > 0 else { return nil }
        let w = Worklog(kind: target.kind, moduleID: target.moduleID, categoryID: target.categoryID,
                        activity: activity ?? ActivityKind.defaultFor(target.kind), start: start, minutes: minutes,
                        note: note, title: title, source: source, taskID: taskID, deadlineID: deadlineID,
                        blockID: blockID, eventKey: eventKey)
        worklogs.append(w)
        if let eventKey { skipped[eventKey] = nil }
        return w
    }

    func updateWorklog(_ id: UUID, _ change: (inout Worklog) -> Void) {
        guard let i = worklogs.firstIndex(where: { $0.id == id }) else { return }
        var w = worklogs[i]
        change(&w)
        worklogs[i] = w
    }

    func worklog(eventKey: String) -> Worklog? { worklogs.first { $0.eventKey == eventKey } }

    func category(_ id: UUID?) -> TimeCategory? { timeCategories.first { $0.id == id } }

    /// Name, Farbe und Symbol eines Buchungsziels.
    func label(for t: TrackTarget) -> (name: String, color: Color, symbol: String) {
        switch t.kind {
        case .module:
            if let m = module(t.moduleID) { return (m.name, m.color.color, "book.closed") }
            return ("Gelöschtes Modul", .gray, "book.closed")
        case .work:
            return ("Arbeit", Color(platform: .systemGray), "briefcase")
        case .custom:
            if let c = category(t.categoryID) { return (c.name, c.color.color, c.symbol) }
            return ("Sonstiges", .secondary, "tag")
        }
    }

    /// Alle Ziele, auf die gebucht werden kann (für Auswahllisten).
    var trackTargets: [TrackTarget] {
        activeModules.map { .module($0.id) } + [.work] + timeCategories.filter { !$0.archived }.map { .custom($0.id) }
    }

    /// Findet ein Ziel per Name (für die KI): Modul, „Arbeit“ oder eigene Kategorie.
    func findTarget(_ ref: String?) -> TrackTarget? {
        guard let ref = ref?.trimmed, !ref.isEmpty else { return nil }
        let l = ref.lowercased()
        if ["arbeit", "work", "werkstudent", "job"].contains(l) { return .work }
        if let c = timeCategories.first(where: { $0.id.uuidString == ref || $0.name.lowercased() == l }) { return .custom(c.id) }
        if let m = findModule(ref) { return .module(m.id) }
        if let c = timeCategories.first(where: { $0.name.lowercased().contains(l) }) { return .custom(c.id) }
        return nil
    }

    func rule(forTitle title: String) -> CategoryRule? {
        let k = CategoryRule.normalize(title)
        return categoryRules.first { $0.key == k }
    }

    func remember(title: String, target: TrackTarget, activity: ActivityKind) {
        let k = CategoryRule.normalize(title)
        guard !k.isEmpty else { return }
        categoryRules.removeAll { $0.key == k }
        categoryRules.append(CategoryRule(key: k, title: title, kind: target.kind, moduleID: target.moduleID,
                                          categoryID: target.categoryID, activity: activity))
    }

    /// Gebuchte Zeit auf eine Aufgabe bzw. Frist (Jira: „Logged“).
    func logged(taskID: UUID) -> Int { worklogs.filter { $0.taskID == taskID }.reduce(0) { $0 + $1.minutes } }
    func logged(deadlineID: UUID) -> Int { worklogs.filter { $0.deadlineID == deadlineID }.reduce(0) { $0 + $1.minutes } }

    // MARK: Karteikarten

    func dueCards(moduleID: UUID? = nil, now: Date = Date()) -> [Flashcard] {
        let active = Set(activeModules.map(\.id))
        return flashcards.filter { c in
            (moduleID == nil ? active.contains(c.moduleID) : c.moduleID == moduleID) && c.due <= now
        }.sorted { $0.due < $1.due }
    }

    // MARK: Themen

    /// Passt die Sicherheit eines Themas anhand eines Ergebnisses an (gleitender Mittelwert).
    func applyResult(moduleID: UUID, topicName: String, score: Double, weight: Double = 0.5) {
        let name = topicName.trimmed
        guard !name.isEmpty else { return }
        updateModule(moduleID) { m in
            let l = name.lowercased()
            if let i = m.topics.firstIndex(where: { $0.title.lowercased() == l })
                ?? m.topics.firstIndex(where: { $0.title.lowercased().contains(l) || l.contains($0.title.lowercased()) }) {
                let old = m.topics[i].confidence
                m.topics[i].confidence = min(1, max(0, old * (1 - weight) + score * weight))
                m.topics[i].lastReviewed = Date()
                m.topics[i].covered = true
            } else {
                m.topics.append(Topic(title: name, confidence: score * weight, covered: true, lastReviewed: Date()))
            }
        }
    }

    // MARK: Chats

    func loadChats() -> [String: ChatThread] {
        guard let data = CoordinatedFile.read(Paths.chatsFile),
              let threads = try? JSONCoding.decoder.decode([String: ChatThread].self, from: data) else { return [:] }
        return threads
    }

    func saveChats(_ threads: [String: ChatThread]) {
        guard let data = try? JSONCoding.encoder.encode(threads) else { return }
        CoordinatedFile.write(data, to: Paths.chatsFile)
    }
}
