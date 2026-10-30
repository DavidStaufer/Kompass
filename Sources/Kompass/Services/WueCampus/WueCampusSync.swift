import Foundation
import Observation
import UserNotifications

/// Holt Dateien, Abgaben und Termine aus WueCampus in die verknüpften Module.
@MainActor
@Observable
final class WueCampusSync {
    struct Report {
        var newFiles: [String] = []
        var updatedFiles = 0
        var newDeadlines: [String] = []
        var updatedDeadlines = 0
        var skipped = 0
        var errors: [String] = []

        var summary: String {
            var parts: [String] = []
            if !newFiles.isEmpty { parts.append("\(newFiles.count) neue Datei\(newFiles.count == 1 ? "" : "en")") }
            if updatedFiles > 0 { parts.append("\(updatedFiles) aktualisiert") }
            if !newDeadlines.isEmpty { parts.append("\(newDeadlines.count) neue Frist\(newDeadlines.count == 1 ? "" : "en")") }
            if updatedDeadlines > 0 { parts.append("\(updatedDeadlines) Termin\(updatedDeadlines == 1 ? "" : "e") geändert") }
            if parts.isEmpty { parts.append("Alles aktuell") }
            return parts.joined(separator: " · ")
        }
        var hasNews: Bool { !newFiles.isEmpty || !newDeadlines.isEmpty || updatedFiles > 0 || updatedDeadlines > 0 }
    }

    @ObservationIgnored private let store: DataStore
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let auth = MoodleAuth()
    private static let tokenAccount = "wuecampus-token"

    var account: String? = UserDefaults.standard.string(forKey: "wue.account")
    var isSyncing = false
    var status: String?
    var lastReport: Report?
    var lastError: String?
    var courses: [MoodleClient.Course] = []
    var loadingCourses = false
    /// Nur auf diesem Gerät automatisch synchronisieren (Standard: Mac ja, iPhone nein)
    var autoSync: Bool = UserDefaults.standard.object(forKey: "wue.autoSync") as? Bool ?? Platform.isMac {
        didSet { UserDefaults.standard.set(autoSync, forKey: "wue.autoSync"); scheduleTimer() }
    }

    init(store: DataStore) {
        self.store = store
    }

    // MARK: Verbindung

    var site: URL {
        if let s = UserDefaults.standard.string(forKey: "kompass.wueSite"), let u = URL(string: s) { return u }
        return MoodleClient.wueCampus
    }

    private var token: String? {
        if Paths.isDemo, let t = UserDefaults.standard.string(forKey: "kompass.wueToken") { return t }
        return Keychain.get(Self.tokenAccount)
    }

    var isConnected: Bool { token != nil }

    var client: MoodleClient? { token.map { MoodleClient(site: site, token: $0) } }

    var linkedModules: [Module] { store.modules.filter { $0.wueCourseID != nil && !$0.archived } }

    func connect() async {
        lastError = nil
        do {
            let t = try await auth.login(site: site)
            try await finishConnect(token: t)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Alternative: Schlüssel aus WueCampus → Profil → Einstellungen → Sicherheitsschlüssel einfügen.
    func connect(manualToken: String) async {
        lastError = nil
        do { try await finishConnect(token: manualToken.trimmed) } catch { lastError = error.localizedDescription }
    }

    private func finishConnect(token t: String) async throws {
        let info = try await MoodleClient(site: site, token: t).siteInfo()
        if !Paths.isDemo { Keychain.set(t, for: Self.tokenAccount, label: "Kompass – WueCampus-Zugang") }
        account = info.fullname
        UserDefaults.standard.set(info.fullname, forKey: "wue.account")
        await loadCourses()
        scheduleTimer()
    }

    func disconnect() {
        if !Paths.isDemo { Keychain.set(nil, for: Self.tokenAccount, label: "Kompass – WueCampus-Zugang") }
        account = nil
        UserDefaults.standard.removeObject(forKey: "wue.account")
        courses = []
        timer?.invalidate()
    }

    func loadCourses() async {
        guard let client else { return }
        loadingCourses = true
        defer { loadingCourses = false }
        do {
            courses = try await client.currentCourses().filter { $0.hidden != true }
        } catch {
            handle(error)
        }
    }

    // MARK: Automatik

    func start() {
        scheduleTimer()
        if autoSync, isConnected, !linkedModules.isEmpty {
            Task { await sync(manual: false) }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard autoSync, isConnected else { return }
        let t = Timer(timeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync(manual: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Synchronisieren

    @discardableResult
    func sync(manual: Bool, onlyModule: UUID? = nil) async -> Report? {
        guard !isSyncing, let client else { return nil }
        let modules = linkedModules.filter { onlyModule == nil || $0.id == onlyModule }
        guard !modules.isEmpty else {
            if manual { lastError = "Noch keine Kurse zugeordnet." }
            return nil
        }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false; status = nil }
        // Zuerst Stand des anderen Geräts übernehmen, damit nichts doppelt geladen wird
        store.checkForRemoteChanges()

        var report = Report()
        let prefs = store.prefs
        do {
            if prefs.wueSyncFiles {
                for m in modules {
                    guard let cid = m.wueCourseID else { continue }
                    status = "Lade Dateien: \(m.name) …"
                    try await syncFiles(client: client, module: m, courseID: cid, report: &report)
                }
            }
            let courseMap = Dictionary(modules.compactMap { m in m.wueCourseID.map { ($0, m.id) } }, uniquingKeysWith: { a, _ in a })
            if prefs.wueSyncAssignments || prefs.wueSyncFiles {
                status = "Prüfe Abgaben …"
                let assigns = try await client.assignments(courseIDs: Array(courseMap.keys))
                if prefs.wueSyncFiles {
                    // Übungsblätter hängen oft an der Abgabe statt im Kursabschnitt
                    for a in assigns {
                        guard let m = a.course.flatMap({ courseMap[$0] }).flatMap({ store.module($0) }) else { continue }
                        try await syncAssignmentFiles(client: client, assignment: a, module: m, report: &report)
                    }
                }
                if prefs.wueSyncAssignments {
                    for a in assigns { applyAssignment(a, moduleID: a.course.flatMap { courseMap[$0] }, report: &report) }
                }
            }
            if prefs.wueSyncEvents {
                status = "Prüfe Termine …"
                let events = try await client.events(courseIDs: Array(courseMap.keys), from: Date().adding(days: -14), to: Date().adding(days: 240))
                for e in events where e.modulename != "assign" {
                    applyEvent(e, moduleID: e.courseid.flatMap { courseMap[$0] }, report: &report)
                }
            }
        } catch {
            handle(error)
            report.errors.append(error.localizedDescription)
        }
        store.prefs.wueLastSync = Date()
        lastReport = report
        if manual {
            if let e = report.errors.first, !report.hasNews {
                app?.showToast(e, error: true)
            } else {
                app?.showToast("WueCampus: \(report.summary)", symbol: "arrow.triangle.2.circlepath")
            }
        } else if report.hasNews {
            notify(report)
        }
        return report
    }

    private func handle(_ error: Error) {
        if let e = error as? MoodleClient.MoodleError, e.isAuthError {
            if !Paths.isDemo { Keychain.set(nil, for: Self.tokenAccount, label: "Kompass – WueCampus-Zugang") }
            account = nil
        }
        lastError = error.localizedDescription
    }

    // MARK: Dateien

    private static let skipExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mp3", "wav", "m4a", "zip", "rar", "7z", "exe", "dmg"]

    private func syncFiles(client: MoodleClient, module: Module, courseID: Int, report: inout Report) async throws {
        let sections = try await client.contents(courseID: courseID)
        for section in sections {
            for cm in section.modules ?? [] where ["resource", "folder"].contains(cm.modname ?? "") {
                for f in cm.contents ?? [] where (f.type ?? "file") == "file" {
                    guard let name = f.filename else { continue }
                    try await syncFile(f, key: "wue:file:\(cm.id):\(f.filepath ?? "/")\(name)", client: client, module: module, report: &report) {
                        (self.materialTitle(module: cm, file: name), self.guessKind(file: name, moduleName: cm.name, section: section.name))
                    }
                }
            }
        }
    }

    /// Anhänge einer Abgabe (meist das Aufgabenblatt) – landen als Übung im Modul.
    private func syncAssignmentFiles(client: MoodleClient, assignment a: MoodleClient.Assignment, module: Module, report: inout Report) async throws {
        let files = (a.introattachments ?? []).filter { !($0.filename ?? ".").hasPrefix(".") }
        for f in files {
            guard let name = f.filename else { continue }
            let key = "wue:assignfile:\(a.id):\(f.filepath ?? "/")\(name)"
            // Alles an einer Abgabe gehört zur Übung (früher teils als Skript/Vorlesung einsortiert)
            let kind: MaterialKind = name.lowercased().range(of: "l(ö|oe)sung|solution", options: .regularExpression) != nil ? .loesung : .uebung
            if let (_, existing) = existingMaterial(key), existing.kind != kind {
                store.updateMaterial(existing.id) { $0.kind = kind }
            }
            try await syncFile(f, key: key, client: client, module: module, report: &report) {
                let base = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
                let title = files.count == 1 ? a.name.htmlDecoded : "\(a.name.htmlDecoded) – \(base)"
                return (title, kind)
            }
        }
    }

    /// Lädt eine Datei neu oder aktualisiert sie, wenn sie sich in WueCampus geändert hat.
    private func syncFile(_ f: MoodleClient.FileContent, key: String, client: MoodleClient, module: Module, report: inout Report,
                          describe: () -> (title: String, kind: MaterialKind)) async throws {
        guard let name = f.filename, let fileURL = f.fileurl, !name.hasPrefix(".") else { return }
        let ext = (name as NSString).pathExtension.lowercased()
        if Self.skipExtensions.contains(ext) || (f.mimetype ?? "").hasPrefix("video/") || (f.filesize ?? 0) > store.prefs.wueMaxFileMB * 1_000_000 {
            report.skipped += 1
            return
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(f.timemodified ?? 0))
        if store.prefs.wueIgnoredKeys.contains(key) { return }

        // Schon vorhanden (in irgendeinem Modul)?
        if let (owner, existing) = existingMaterial(key) {
            if let old = existing.sourceModified, modified > old.addingTimeInterval(1) {
                status = "Aktualisiere \(existing.title) …"
                let tmp = try await client.download(fileURL)
                replace(material: existing, in: owner.id, with: tmp, modified: modified)
                report.updatedFiles += 1
            }
            return
        }

        status = "Lade \(name) …"
        let tmp = try await client.download(fileURL)
        let (title, kind) = describe()
        MaterialImporter.importDownloaded(tmp, fileName: name, title: title, kind: kind, moduleID: module.id,
                                          sourceKey: key, sourceModified: modified, store: store)
        report.newFiles.append("\(title) (\(module.name))")
    }

    private func existingMaterial(_ key: String) -> (Module, Material)? {
        for m in store.modules { if let mat = m.materials.first(where: { $0.sourceKey == key }) { return (m, mat) } }
        return nil
    }

    private func replace(material: Material, in moduleID: UUID, with tmp: URL, modified: Date) {
        let dest = Paths.materialFile(moduleID, material)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: tmp, to: dest)
        store.updateMaterial(material.id) { $0.sourceModified = modified }
        MaterialImporter.extract(materialID: material.id, moduleID: moduleID, file: dest, store: store)
    }

    private func materialTitle(module cm: MoodleClient.CourseModule, file: String) -> String {
        let base = (file as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        guard let n = cm.name?.trimmed, !n.isEmpty else { return base }
        if cm.modname == "folder" { return "\(n) – \(base)" }
        return n
    }

    private func guessKind(file: String, moduleName: String?, section: String?) -> MaterialKind {
        for text in [file, moduleName ?? "", section ?? ""] {
            let k = MaterialKind.guess(from: text)
            if k != .sonstiges && k != .notiz { return k }
        }
        return .sonstiges
    }

    // MARK: Fristen

    private func applyAssignment(_ a: MoodleClient.Assignment, moduleID: UUID?, report: inout Report) {
        guard let due = a.duedate, due > 0 else { return }
        let date = Date(timeIntervalSince1970: TimeInterval(due))
        guard date > Date().adding(days: -14) else { return }
        upsertDeadline(key: "wue:assign:\(a.id)", title: a.name.htmlDecoded, kind: .abgabe, date: date, duration: 0,
                       moduleID: moduleID, modified: a.timemodified, url: a.cmid.map { site.appendingPathComponent("mod/assign/view.php").absoluteString + "?id=\($0)" },
                       report: &report)
    }

    private func applyEvent(_ e: MoodleClient.Event, moduleID: UUID?, report: inout Report) {
        let name = e.name.htmlDecoded
        let l = name.lowercased()
        let kind: DeadlineKind
        if l.contains("klausur") || l.contains("prüfung") || l.contains("exam") { kind = .klausur }
        else if l.contains("präsentation") || l.contains("referat") || l.contains("vortrag") { kind = .praesentation }
        else if l.contains("abgabe") || l.contains("deadline") { kind = .abgabe }
        else if e.modulename == "quiz" || l.contains("test") { kind = .testat }
        else { kind = .sonstiges }
        let date = Date(timeIntervalSince1970: TimeInterval(e.timestart))
        upsertDeadline(key: "wue:event:\(e.id)", title: name, kind: kind, date: date, duration: (e.timeduration ?? 0) / 60,
                       moduleID: moduleID, modified: e.timemodified, url: nil, location: e.location ?? "", report: &report)
    }

    private func upsertDeadline(key: String, title: String, kind: DeadlineKind, date: Date, duration: Int, moduleID: UUID?,
                                modified: Int?, url: String?, location: String = "", report: inout Report) {
        if store.prefs.wueIgnoredKeys.contains(key) { return }
        let mod = modified.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if var d = store.deadlines.first(where: { $0.sourceKey == key }) {
            // Nur übernehmen, wenn sich in WueCampus etwas geändert hat (eigene Anpassungen bleiben sonst erhalten)
            guard abs(d.date.timeIntervalSince(date)) > 59 || d.title != title else { return }
            if let mod, let old = d.sourceModified, mod <= old { return }
            d.date = date
            d.title = title
            d.sourceModified = mod
            app?.saveDeadline(d)
            report.updatedDeadlines += 1
            return
        }
        // Schon selbst eingetragen (gleiches Modul, gleiche Art, ähnlicher Titel)? → nur verknüpfen, nicht doppelt anlegen
        let norm = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        if let i = store.deadlines.firstIndex(where: { e in
            e.sourceKey == nil && e.moduleID == moduleID && e.kind == kind && abs(e.date.timeIntervalSince(date)) < 60 * 86400
                && (norm(e.title) == norm(title) || norm(e.title).contains(norm(title)) || norm(title).contains(norm(e.title)))
        }) {
            store.deadlines[i].sourceKey = key
            store.deadlines[i].sourceModified = mod
            if store.deadlines[i].sourceURL == nil { store.deadlines[i].sourceURL = url }
            return
        }
        var d = Deadline(title: title, kind: kind, moduleID: moduleID, date: date)
        d.durationMinutes = duration
        d.location = location
        d.notes = "Aus WueCampus übernommen."
        d.reminderOffsets = kind.defaultOffsets
        d.sourceKey = key
        d.sourceModified = mod
        d.sourceURL = url
        app?.saveDeadline(d)
        report.newDeadlines.append(title)
    }

    // MARK: Hinweise

    /// Gelöschte, übernommene Einträge merken, damit sie nicht wiederkommen.
    func ignore(_ key: String?) {
        guard let key, !store.prefs.wueIgnoredKeys.contains(key) else { return }
        store.prefs.wueIgnoredKeys.append(key)
    }

    private func notify(_ r: Report) {
        guard !Paths.isDemo else { return }
        let content = UNMutableNotificationContent()
        content.title = "Neu in WueCampus"
        content.body = (r.newFiles.prefix(3) + r.newDeadlines.prefix(2)).joined(separator: "\n") + (r.newFiles.count > 3 ? "\n…" : "")
        if content.body.isEmpty { content.body = r.summary }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wue-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil))
    }
}

extension String {
    var htmlDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}
