import Foundation
import SwiftUI
import Observation

enum SidebarItem: Hashable {
    case today, calendar, week, deadlines, cards, time, module(UUID)
}

enum AppSheet: Identifiable {
    case newModule
    case editModule(UUID)
    case deadline(UUID?, moduleID: UUID?, kind: DeadlineKind?)
    case newEvent(start: Date, end: Date, moduleID: UUID?)
    case editEvent(String)
    case planner(Date)
    case quiz(UUID)
    case doc(UUID)
    case generator(GeneratorKind, UUID, [UUID])
    case cardReview(UUID?)
    case task(UUID?, moduleID: UUID?)
    case logWork(LogPreset)
    case term(UUID?)
    case onboarding

    var id: String {
        switch self {
        case .newModule: return "newModule"
        case .editModule(let id): return "editModule-\(id)"
        case .deadline(let id, let m, let k): return "deadline-\(id?.uuidString ?? "new")-\(m?.uuidString ?? "")-\(k?.rawValue ?? "")"
        case .newEvent(let s, _, _): return "newEvent-\(s.timeIntervalSince1970)"
        case .editEvent(let id): return "editEvent-\(id)"
        case .planner(let d): return "planner-\(d.timeIntervalSince1970)"
        case .quiz(let id): return "quiz-\(id)"
        case .doc(let id): return "doc-\(id)"
        case .generator(let k, let m, _): return "gen-\(k.rawValue)-\(m)"
        case .cardReview(let m): return "cards-\(m?.uuidString ?? "all")"
        case .task(let id, _): return "task-\(id?.uuidString ?? "new")"
        case .logWork(let p): return "log-\(p.idString)"
        case .term(let id): return "term-\(id?.uuidString ?? "new")"
        case .onboarding: return "onboarding"
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String = "checkmark.circle.fill"
    var isError = false
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store: DataStore
    let calendar: CalendarService
    let sync: SyncService
    let timer: FocusTimer
    let assistant: Assistant

    var selection: SidebarItem? = .today
    var showAssistant = false
    /// iPhone: Einstellungen als Sheet
    var showSettings = false
    /// Während ein Termin gezogen wird (Wischen zum Blättern pausiert)
    var eventDragActive = false
    var sheet: AppSheet?
    var calendarDate = Date()
    var toast: Toast?
    var moduleTab: ModuleTab = .overview

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var booted = false

    private init() {
        let store = DataStore()
        self.store = store
        let calendar = CalendarService(store: store)
        self.calendar = calendar
        let sync = SyncService(store: store, calendar: calendar)
        self.sync = sync
        let timer = FocusTimer(store: store)
        timer.sync = sync
        self.timer = timer
        self.assistant = Assistant()
        assistant.app = self
        assistant.load(from: store)

        calendar.onExternalChange = { [weak sync] in sync?.reconcile() }
        store.deadlinesChanged = { [weak sync] in sync?.rescheduleNotifications() }
        store.worklogsChanged = { [weak sync] in sync?.rescheduleNotifications() }
        store.reloaded = { [weak self] in
            guard let self else { return }
            self.assistant.load(from: self.store)
            self.calendar.revision += 1
        }
        store.prefsChanged = { [weak self] old in self?.prefsChanged(old) }
    }

    func bootstrap() async {
        guard !booted else { return }
        booted = true
        if let start = UserDefaults.standard.string(forKey: "kompass.startView") {
            switch start {
            case "calendar": selection = .calendar
            case "week": selection = .week
            case "deadlines": selection = .deadlines
            case "cards": selection = .cards
            case "time": selection = .time
            default:
                if let id = store.findModule(start)?.id { selection = .module(id) }
            }
            if let tab = UserDefaults.standard.string(forKey: "kompass.moduleTab").flatMap(ModuleTab.init(rawValue:)) { moduleTab = tab }
            if UserDefaults.standard.bool(forKey: "kompass.showAssistant") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(Motion.standard) { self.showAssistant = true }
                }
            }
        }
        if Paths.isDemo {
            MaterialImporter.resumePending(store: store)
            openDemoSheet(UserDefaults.standard.string(forKey: "kompass.sheet"))
            if UserDefaults.standard.bool(forKey: "kompass.demoConfirm") { confirmAll(pendingConfirmations()) }
            if let d = UserDefaults.standard.string(forKey: "kompass.calendarDate").flatMap({ Fmt.parse($0) }) { calendarDate = d }
            if let q = UserDefaults.standard.string(forKey: "kompass.ask") {
                if let base = UserDefaults.standard.string(forKey: "kompass.demoBaseURL") { store.prefs.aiBaseURL = base }
                showAssistant = true
                assistant.send(q)
            }
            return
        }
        if !store.prefs.onboardingDone {
            sheet = .onboarding
            return
        }
        await finishSetup()
    }

    /// Nach dem Onboarding bzw. beim normalen Start.
    func finishSetup() async {
        await calendar.requestAccess()
        calendar.migrateEventKeys(store: store)
        await sync.requestNotificationPermission()
        MaterialImporter.resumePending(store: store)
        sync.reconcile()
        sync.resyncAll()
        if Date().isoWeekday == 7 || (Date().isoWeekday == 1 && Date().minutesSinceMidnight < 12 * 60) {
            // Sonntags (bzw. Montagmorgen) den Wochenrückblick prominent zeigen
            if selection == nil { selection = .today }
        }
    }

    /// Nur Demo-Modus: öffnet ein Sheet per Startargument (für Screenshots/Tests).
    private func openDemoSheet(_ name: String?) {
        guard let name else { return }
        let m = store.activeModules.first?.id
        switch name {
        case "newModule": sheet = .newModule
        case "editModule": if let m { sheet = .editModule(m) }
        case "deadline": sheet = .deadline(store.deadlines.first?.id, moduleID: nil, kind: nil)
        case "newDeadline": sheet = .deadline(nil, moduleID: m, kind: .klausur)
        case "planner": sheet = .planner(Date().startOfWeek.adding(weeks: 1))
        case "quiz": if let q = store.quizzes.first { sheet = .quiz(q.id) }
        case "doc": if let d = store.docs.first { sheet = .doc(d.id) }
        case "generator": if let m { sheet = .generator(.mockExam, m, []) }
        case "cards": sheet = .cardReview(nil)
        case "onboarding": sheet = .onboarding
        case "event": sheet = .newEvent(start: Date().at(minutes: 14 * 60), end: Date().at(minutes: 15 * 60), moduleID: m)
        case "task": sheet = .task(nil, moduleID: m)
        case "logWork": sheet = .logWork(LogPreset(target: m.map { .module($0) }))
        default: break
        }
    }

    private func prefsChanged(_ old: Preferences) {
        let p = store.prefs
        if p.notifyLocal != old.notifyLocal || p.weeklyReviewEnabled != old.weeklyReviewEnabled || p.weeklyReviewHour != old.weeklyReviewHour
            || p.dailyBriefingEnabled != old.dailyBriefingEnabled || p.dailyBriefingMinutes != old.dailyBriefingMinutes || p.userName != old.userName
            || p.confirmReminderEnabled != old.confirmReminderEnabled || p.confirmReminderMinutes != old.confirmReminderMinutes {
            sync.rescheduleNotifications()
        }
        if p.useRemindersApp != old.useRemindersApp || p.useCalendarAlarms != old.useCalendarAlarms {
            for d in store.deadlines where !d.done { sync.sync(deadlineID: d.id) }
        }
        if p.hiddenCalendarIDs != old.hiddenCalendarIDs { calendar.revision += 1 }
    }

    /// Öffnet ein Sheet aus den Einstellungen heraus (iPhone: Einstellungen erst schließen).
    func presentFromSettings(_ s: AppSheet) {
        #if os(iOS)
        showSettings = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            self.sheet = s
        }
        #else
        sheet = s
        Platform.activateApp()
        #endif
    }

    // MARK: Speicherort (iCloud Drive)

    /// iPhone: Ordner aus iCloud Drive übernehmen. Liefert eine Meldung für den Nutzer.
    func useStorageFolder(_ url: URL) -> String {
        store.saveNow()
        do {
            let hadData = try StorageLocation.shared.useFolder(url)
            store.reloadFromDisk()
            return hadData ? "Verbunden – Daten aus iCloud geladen." : "Verbunden – deine Daten liegen jetzt in iCloud Drive."
        } catch {
            return "Der Ordner konnte nicht verwendet werden: \(error.localizedDescription)"
        }
    }

    func useLocalStorage() {
        store.saveNow()
        StorageLocation.shared.useLocal()
        store.reloadFromDisk()
    }

    #if os(macOS)
    func setMacStorage(iCloud: Bool) {
        store.saveNow()
        if StorageLocation.shared.setMacMode(iCloud ? .iCloud : .local) { store.reloadFromDisk() }
    }
    #endif

    // MARK: Navigation

    func open(_ item: SidebarItem) {
        selection = item
    }

    func openModule(_ id: UUID, tab: ModuleTab? = nil) {
        if let tab { moduleTab = tab }
        selection = .module(id)
    }

    func handle(url: URL) {
        guard let link = KompassLink(url: url) else { return }
        switch link.kind {
        case .deadline: selection = .deadlines
            if let id = link.id { sheet = .deadline(id, moduleID: nil, kind: nil) }
        case .module, .session, .block:
            if let m = link.moduleID { openModule(m) }
        case .event: selection = .calendar
        }
    }

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill", error: Bool = false) {
        toastTask?.cancel()
        withAnimation(Motion.standard) { toast = Toast(text: text, symbol: error ? "exclamationmark.triangle.fill" : symbol, isError: error) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.standard) { self?.toast = nil }
        }
    }

    // MARK: Fristen

    func saveDeadline(_ d: Deadline) {
        if let i = store.deadlines.firstIndex(where: { $0.id == d.id }) {
            store.deadlines[i] = d
        } else {
            store.deadlines.append(d)
        }
        sync.sync(deadlineID: d.id)
    }

    func deleteDeadline(_ id: UUID) {
        guard let d = store.deadline(id) else { return }
        sync.remove(deadline: d)
        store.deadlines.removeAll { $0.id == id }
    }

    func toggleDeadline(_ id: UUID) {
        store.updateDeadline(id) { d in
            d.done.toggle()
            d.doneAt = d.done ? Date() : nil
        }
        sync.sync(deadlineID: id)
    }

    // MARK: Veranstaltungen

    func addSession(_ s: CourseSession, to moduleID: UUID) {
        store.updateModule(moduleID) { $0.sessions.append(s) }
        sync.syncSessions(moduleID: moduleID)
    }

    func updateSession(_ s: CourseSession, in moduleID: UUID) {
        store.updateModule(moduleID) { m in
            if let i = m.sessions.firstIndex(where: { $0.id == s.id }) { m.sessions[i] = s }
        }
        sync.syncSessions(moduleID: moduleID)
    }

    func removeSession(_ sessionID: UUID, from moduleID: UUID) {
        guard let s = store.module(moduleID)?.sessions.first(where: { $0.id == sessionID }) else { return }
        sync.removeSession(s)
        store.updateModule(moduleID) { $0.sessions.removeAll { $0.id == sessionID } }
    }

}

enum ModuleTab: String, CaseIterable, Identifiable {
    case overview, topics, materials, learn, docs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .overview: return "Übersicht"
        case .topics: return "Themen"
        case .materials: return "Materialien"
        case .learn: return "Lernen"
        case .docs: return "Dokumente"
        }
    }
}
