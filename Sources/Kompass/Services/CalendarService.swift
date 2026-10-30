import Foundation
import EventKit
import SwiftUI
import Observation

/// Verknüpfung zwischen einem Kalendertermin und einem Kompass-Objekt (über die Termin-URL).
struct KompassLink: Hashable {
    enum Kind: String { case block, deadline, session, event, module }
    var kind: Kind
    var id: UUID?
    var moduleID: UUID?

    var url: URL {
        var c = URLComponents()
        c.scheme = "kompass"
        c.host = kind.rawValue
        c.path = id.map { "/" + $0.uuidString } ?? ""
        if let moduleID { c.queryItems = [URLQueryItem(name: "module", value: moduleID.uuidString)] }
        return c.url!
    }

    init(kind: Kind, id: UUID? = nil, moduleID: UUID? = nil) {
        self.kind = kind; self.id = id; self.moduleID = moduleID
    }

    init?(url: URL?) {
        guard let url, url.scheme == "kompass", let host = url.host, let k = Kind(rawValue: host) else { return nil }
        kind = k
        id = UUID(uuidString: url.lastPathComponent)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        moduleID = comps?.queryItems?.first(where: { $0.name == "module" })?.value.flatMap(UUID.init(uuidString:))
        if k == .module { moduleID = moduleID ?? id }
    }
}

/// Leichtgewichtige, SwiftUI-freundliche Kopie eines EKEvent.
struct CalEvent: Identifiable, Hashable {
    let id: String
    let eventIdentifier: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String
    var notes: String
    let calendarID: String
    let calendarTitle: String
    let calendarColor: Color
    let editable: Bool
    let isRecurring: Bool
    let isFree: Bool
    let link: KompassLink?

    var moduleID: UUID? { link?.moduleID }
    var minutes: Int { Int(end.timeIntervalSince(start) / 60) }

    init(_ e: EKEvent, overrideID: String? = nil) {
        let local = e.eventIdentifier ?? e.calendarItemIdentifier
        // Stabiler Schlüssel über Geräte hinweg (iCloud-UID), bei Serien plus Vorkommen
        let stable = overrideID ?? (e.calendarItemExternalIdentifier?.nilIfEmpty ?? local)
        let recurring = e.hasRecurrenceRules || e.isDetached
        let occ = e.occurrenceDate ?? e.startDate ?? Date()
        id = recurring ? "\(stable)|\(Int(occ.timeIntervalSince1970))" : stable
        eventIdentifier = overrideID ?? local
        title = e.title ?? "Ohne Titel"
        start = e.startDate ?? Date()
        end = e.endDate ?? start
        isAllDay = e.isAllDay
        location = e.location ?? ""
        notes = e.notes ?? ""
        calendarID = e.calendar?.calendarIdentifier ?? ""
        calendarTitle = e.calendar?.title ?? ""
        if let cg = e.calendar?.cgColor { calendarColor = Color(cgColor: cg) } else { calendarColor = .gray }
        editable = e.calendar?.allowsContentModifications ?? false
        isRecurring = recurring
        isFree = e.availability == .free
        link = KompassLink(url: e.url)
    }
}

enum CalendarError: LocalizedError {
    case noAccess, noCalendar, notFound, readOnly
    var errorDescription: String? {
        switch self {
        case .noAccess: return "Kein Zugriff auf Apple Kalender. Bitte in den Systemeinstellungen → Datenschutz → Kalender erlauben."
        case .noCalendar: return "Der Kompass-Kalender konnte nicht angelegt werden."
        case .notFound: return "Der Termin wurde nicht gefunden (evtl. wurde er inzwischen gelöscht)."
        case .readOnly: return "Dieser Kalender ist schreibgeschützt."
        }
    }
}

@MainActor
@Observable
final class CalendarService {
    @ObservationIgnored let ek = EKEventStore()
    @ObservationIgnored private let store: DataStore
    @ObservationIgnored private var cache: [String: EKEvent] = [:]
    /// Ergebnisse von `events(from:to:)` je Zeitraum – Views fragen beim Rendern oft dasselbe ab.
    /// Gilt nur für die aktuelle `revision`; jede Änderung am Kalender leert ihn.
    @ObservationIgnored private var queryCache: [QueryKey: [CalEvent]] = [:]
    @ObservationIgnored private var queryCacheRevision = -1
    private struct QueryKey: Hashable { let start: Date; let end: Date; let calendars: [String] }
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Wird nach jeder externen Änderung aufgerufen (Abgleich mit Kompass-Objekten).
    @ObservationIgnored var onExternalChange: (() -> Void)?

    var eventStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    var reminderStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    var calendars: [EKCalendar] = []
    /// Erhöht sich bei jeder Änderung – Views lesen es, um neu zu laden.
    var revision = 0
    var lastError: String?

    var eventsAuthorized: Bool { !Paths.isDemo && eventStatus == .fullAccess }
    var remindersAuthorized: Bool { !Paths.isDemo && reminderStatus == .fullAccess }

    init(store: DataStore) {
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.externalChange() }
        }
        if eventsAuthorized { reloadCalendars() }
    }

    // MARK: Zugriff

    func requestAccess() async {
        if eventStatus == .notDetermined || eventStatus == .writeOnly {
            _ = try? await ek.requestFullAccessToEvents()
        }
        if reminderStatus == .notDetermined || reminderStatus == .writeOnly {
            _ = try? await ek.requestFullAccessToReminders()
        }
        eventStatus = EKEventStore.authorizationStatus(for: .event)
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        if eventsAuthorized {
            ek.refreshSourcesIfNecessary()
            reloadCalendars()
            _ = ensureKompassCalendar()
        }
        if remindersAuthorized { _ = ensureReminderList() }
    }

    func openPrivacySettings(reminders: Bool = false) {
        Platform.openPrivacySettings(reminders: reminders)
    }

    private func externalChange() {
        reloadCalendars()
        onExternalChange?()
    }

    func reloadCalendars() {
        guard eventsAuthorized else { calendars = []; return }
        calendars = ek.calendars(for: .event).sorted { a, b in
            if a.source.title != b.source.title { return a.source.title < b.source.title }
            return a.title < b.title
        }
        cache.removeAll()
        revision += 1
        resolveWorkCalendar()
    }

    /// Arbeitskalender per Titel zuordnen, wenn die (gerätespezifische) ID hier unbekannt ist.
    private func resolveWorkCalendar() {
        let p = store.prefs
        if let id = p.workCalendarID, calendars.contains(where: { $0.calendarIdentifier == id }) {
            if p.workCalendarTitle == nil, let c = calendar(id) { store.prefs.workCalendarTitle = c.title }
            return
        }
        guard let title = p.workCalendarTitle, let c = calendars.first(where: { $0.title == title }) else { return }
        store.prefs.workCalendarID = c.calendarIdentifier
    }

    var editableCalendars: [EKCalendar] { calendars.filter(\.allowsContentModifications) }

    var visibleCalendars: [EKCalendar] {
        let hidden = Set(store.prefs.hiddenCalendarIDs)
        return calendars.filter { !hidden.contains($0.calendarIdentifier) }
    }

    func calendar(_ id: String?) -> EKCalendar? {
        guard let id else { return nil }
        return ek.calendar(withIdentifier: id)
    }

    // MARK: Kompass-Kalender & Erinnerungsliste

    var kompassCalendar: EKCalendar? {
        guard let id = store.prefs.kompassCalendarID, let c = ek.calendar(withIdentifier: id), c.allowsContentModifications else { return nil }
        return c
    }

    @discardableResult
    func ensureKompassCalendar() -> EKCalendar? {
        guard eventsAuthorized else { return nil }
        if let c = kompassCalendar { return c }
        if let c = ek.calendars(for: .event).first(where: { $0.title == "Kompass" && $0.allowsContentModifications }) {
            store.prefs.kompassCalendarID = c.calendarIdentifier
            return c
        }
        for source in preferredSources(for: .event) {
            let c = EKCalendar(for: .event, eventStore: ek)
            c.title = "Kompass"
            c.cgColor = PlatformColor.systemIndigo.cgColor
            c.source = source
            do {
                try ek.saveCalendar(c, commit: true)
                store.prefs.kompassCalendarID = c.calendarIdentifier
                reloadCalendars()
                return c
            } catch {
                continue
            }
        }
        lastError = CalendarError.noCalendar.localizedDescription
        return nil
    }

    var reminderList: EKCalendar? {
        guard let id = store.prefs.reminderListID, let c = ek.calendar(withIdentifier: id) else { return nil }
        return c
    }

    @discardableResult
    func ensureReminderList() -> EKCalendar? {
        guard remindersAuthorized else { return nil }
        if let c = reminderList { return c }
        if let c = ek.calendars(for: .reminder).first(where: { $0.title == "Kompass" }) {
            store.prefs.reminderListID = c.calendarIdentifier
            return c
        }
        for source in preferredSources(for: .reminder) {
            let c = EKCalendar(for: .reminder, eventStore: ek)
            c.title = "Kompass"
            c.cgColor = PlatformColor.systemIndigo.cgColor
            c.source = source
            do {
                try ek.saveCalendar(c, commit: true)
                store.prefs.reminderListID = c.calendarIdentifier
                return c
            } catch { continue }
        }
        return ek.defaultCalendarForNewReminders()
    }

    /// iCloud zuerst (damit alles auf iPhone/Watch erscheint), dann Standardquelle, dann lokal.
    private func preferredSources(for type: EKEntityType) -> [EKSource] {
        var result: [EKSource] = []
        let sources = ek.sources
        if let icloud = sources.first(where: { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }) {
            result.append(icloud)
        }
        let def = type == .event ? ek.defaultCalendarForNewEvents?.source : ek.defaultCalendarForNewReminders()?.source
        if let def, !result.contains(where: { $0.sourceIdentifier == def.sourceIdentifier }) { result.append(def) }
        for s in sources where s.sourceType == .local && !result.contains(where: { $0.sourceIdentifier == s.sourceIdentifier }) {
            result.append(s)
        }
        return result
    }

    // MARK: Termine lesen

    /// Im Demo-Modus werden Termine aus den Kompass-Daten simuliert (ohne Kalenderzugriff).
    var canShowEvents: Bool { eventsAuthorized || Paths.isDemo }

    func events(from start: Date, to end: Date, calendars cals: [EKCalendar]? = nil) -> [CalEvent] {
        let rev = revision
        if Paths.isDemo { return demoEvents(from: start, to: end) }
        guard eventsAuthorized else { return [] }
        let list = cals ?? visibleCalendars
        guard !list.isEmpty, end > start else { return [] }
        if queryCacheRevision != rev { queryCache.removeAll(); queryCacheRevision = rev }
        let key = QueryKey(start: start, end: end, calendars: list.map(\.calendarIdentifier))
        if let hit = queryCache[key] { return hit }
        let pred = ek.predicateForEvents(withStart: start, end: end, calendars: list)
        let evs = ek.events(matching: pred)
        var out: [CalEvent] = []
        out.reserveCapacity(evs.count)
        for e in evs {
            let ce = CalEvent(e)
            cache[ce.id] = e
            out.append(ce)
        }
        out.sort { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }
        if queryCache.count >= 64 { queryCache.removeAll() }
        queryCache[key] = out
        return out
    }

    /// Alle Termine (unabhängig von der Sichtbarkeit) – für Planung und Konflikterkennung.
    func allEvents(from start: Date, to end: Date) -> [CalEvent] {
        events(from: start, to: end, calendars: calendars)
    }

    func ekEvent(for ce: CalEvent) -> EKEvent? { ekEvent(id: ce.id) }

    func ekEvent(id: String) -> EKEvent? {
        if let e = cache[id] { return e }
        let parts = id.split(separator: "|")
        let ident = String(parts.first ?? "")
        if parts.count == 2, let ts = Double(parts[1]) {
            let day = Date(timeIntervalSince1970: ts)
            let pred = ek.predicateForEvents(withStart: day.startOfDay.adding(days: -1), end: day.endOfDay.adding(days: 1), calendars: nil)
            if let e = ek.events(matching: pred).first(where: {
                ($0.calendarItemExternalIdentifier == ident || ($0.eventIdentifier ?? "") == ident)
                    && abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince1970 - ts) < 1
            }) {
                return e
            }
        }
        return findEvent(local: ident, external: ident)
    }

    /// Findet einen Termin über die geräteübergreifende (bevorzugt) oder die lokale Kennung.
    func findEvent(local: String?, external: String?) -> EKEvent? {
        guard eventsAuthorized else { return nil }
        if let external, !external.isEmpty {
            let items = ek.calendarItems(withExternalIdentifier: external).compactMap { $0 as? EKEvent }
            if let e = items.first(where: { !$0.isDetached }) ?? items.first { return e }
        }
        if let local, !local.isEmpty, let e = ek.event(withIdentifier: local) { return e }
        return nil
    }

    /// Sucht einen Kompass-Termin über seine Verknüpfung (z. B. wenn er auf einem anderen Gerät angelegt wurde).
    func findEvent(link: KompassLink, near date: Date, days: Int = 400) -> EKEvent? {
        guard eventsAuthorized, let cal = kompassCalendar else { return nil }
        let url = link.url.absoluteString
        var start = date.adding(days: -days)
        let end = date.adding(days: days)
        // EventKit erlaubt höchstens ~4 Jahre pro Abfrage – in Jahresschritten suchen
        while start < end {
            let stop = min(end, start.adding(days: 360))
            let pred = ek.predicateForEvents(withStart: start, end: stop, calendars: [cal])
            if let e = ek.events(matching: pred).first(where: { $0.url?.absoluteString == url }) { return e }
            start = stop
        }
        return nil
    }

    func findReminder(local: String?, external: String?) -> EKReminder? {
        guard remindersAuthorized else { return nil }
        if let external, !external.isEmpty,
           let r = ek.calendarItems(withExternalIdentifier: external).compactMap({ $0 as? EKReminder }).first { return r }
        return reminder(local)
    }

    // MARK: Auf diesem Gerät gesehene Kompass-Termine (geräte-lokal)

    func markSeen(_ key: String?) {
        guard let key, !key.isEmpty else { return }
        var seen = UserDefaults.standard.stringArray(forKey: "calendar.seen") ?? []
        guard !seen.contains(key) else { return }
        seen.append(key)
        if seen.count > 3000 { seen.removeFirst(seen.count - 3000) }
        UserDefaults.standard.set(seen, forKey: "calendar.seen")
    }

    func wasSeen(_ key: String?) -> Bool {
        guard let key else { return false }
        return (UserDefaults.standard.stringArray(forKey: "calendar.seen") ?? []).contains(key)
    }

    /// Einmalig: Zeitbuchungen auf geräteübergreifende Termin-Schlüssel umstellen.
    func migrateEventKeys(store: DataStore) {
        guard eventsAuthorized, !UserDefaults.standard.bool(forKey: "migration.eventKeys.v2") else { return }
        var changed = false
        var logs = store.worklogs
        for i in logs.indices {
            guard let key = logs[i].eventKey, !key.hasPrefix("work|"), !key.hasPrefix("block|"), !key.hasPrefix("demo|") else { continue }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard let e = ek.event(withIdentifier: parts[0]), let ext = e.calendarItemExternalIdentifier, !ext.isEmpty, ext != parts[0] else { continue }
            logs[i].eventKey = parts.count == 2 ? "\(ext)|\(parts[1])" : ext
            changed = true
        }
        if changed { store.worklogs = logs }
        UserDefaults.standard.set(true, forKey: "migration.eventKeys.v2")
    }

    // MARK: Termine schreiben

    struct EventDraft {
        var title: String
        var start: Date
        var end: Date
        var allDay = false
        var calendarID: String?
        var location = ""
        var notes = ""
        var link: KompassLink?
        var alarmMinutes: [Int] = []
        var recurrence: EKRecurrenceRule?
    }

    @discardableResult
    func create(_ d: EventDraft) throws -> EKEvent {
        guard eventsAuthorized else { throw CalendarError.noAccess }
        let cal = calendar(d.calendarID) ?? ensureKompassCalendar()
        guard let cal else { throw CalendarError.noCalendar }
        guard cal.allowsContentModifications else { throw CalendarError.readOnly }
        let e = EKEvent(eventStore: ek)
        e.calendar = cal
        apply(d, to: e)
        try ek.save(e, span: .thisEvent, commit: true)
        revision += 1
        return e
    }

    func apply(_ d: EventDraft, to e: EKEvent) {
        e.title = d.title
        e.isAllDay = d.allDay
        e.startDate = d.allDay ? d.start.startOfDay : d.start
        e.endDate = d.allDay ? max(d.end, d.start).startOfDay : max(d.end, d.start.adding(minutes: 5))
        e.location = d.location.nilIfEmpty
        e.notes = d.notes.nilIfEmpty
        if let link = d.link { e.url = link.url }
        e.alarms = d.alarmMinutes.isEmpty ? nil : d.alarmMinutes.map { EKAlarm(relativeOffset: -Double($0) * 60) }
        if let r = d.recurrence { e.recurrenceRules = [r] }
    }

    func save(_ e: EKEvent, span: EKSpan = .thisEvent) throws {
        guard e.calendar?.allowsContentModifications ?? false else { throw CalendarError.readOnly }
        try ek.save(e, span: span, commit: true)
        revision += 1
    }

    func move(_ ce: CalEvent, to start: Date, end: Date) throws {
        guard let e = ekEvent(for: ce) else { throw CalendarError.notFound }
        e.startDate = start
        e.endDate = end
        try save(e)
    }

    func delete(_ ce: CalEvent, futureEvents: Bool = false) throws {
        guard let e = ekEvent(for: ce) else { throw CalendarError.notFound }
        try deleteEvent(e, futureEvents: futureEvents)
    }

    func deleteEvent(_ e: EKEvent, futureEvents: Bool = false) throws {
        guard e.calendar?.allowsContentModifications ?? false else { throw CalendarError.readOnly }
        try ek.remove(e, span: futureEvents ? .futureEvents : .thisEvent, commit: true)
        revision += 1
    }

    func deleteEvent(identifier: String?, external: String? = nil, futureEvents: Bool = false) {
        guard let e = findEvent(local: identifier, external: external) else { return }
        try? deleteEvent(e, futureEvents: futureEvents)
    }

    // MARK: Erinnerungen-App

    func reminder(_ id: String?) -> EKReminder? {
        guard let id, remindersAuthorized else { return nil }
        return ek.calendarItem(withIdentifier: id) as? EKReminder
    }

    func saveReminder(_ r: EKReminder) throws {
        try ek.save(r, commit: true)
    }

    func removeReminder(_ id: String?, external: String? = nil) {
        guard let r = findReminder(local: id, external: external) else { return }
        try? ek.remove(r, commit: true)
    }

    private func demoEvents(from start: Date, to end: Date) -> [CalEvent] {
        var out: [CalEvent] = []
        func add(_ title: String, _ s: Date, _ e: Date, _ link: KompassLink?, allDay: Bool = false, location: String = "") {
            guard s < end && e > start else { return }
            let ev = EKEvent(eventStore: ek)
            ev.title = title; ev.startDate = s; ev.endDate = e; ev.isAllDay = allDay; ev.url = link?.url; ev.location = location
            out.append(CalEvent(ev, overrideID: "demo|\(title)|\(Int(s.timeIntervalSince1970))"))
        }
        var day = start.startOfDay
        while day < end {
            for m in store.activeModules {
                for s in m.sessions where s.weekday == day.isoWeekday {
                    add("\(m.displayCode) \(s.kind.short): \(m.name)", day.at(minutes: s.startMinutes), day.at(minutes: s.endMinutes),
                        KompassLink(kind: .session, id: s.id, moduleID: m.id), location: s.room)
                }
            }
            if day.isoWeekday == 3 { add("Zahnarzt", day.at(minutes: 16 * 60), day.at(minutes: 17 * 60), nil) }
            if day.isoWeekday == 6 { add("Fußball", day.at(minutes: 17 * 60), day.at(minutes: 19 * 60), nil) }
            day = day.adding(days: 1)
        }
        for b in store.blocks {
            add("Lernen: \(store.module(b.moduleID)?.name ?? "")" + (b.focus.isEmpty ? "" : " – \(b.focus)"), b.start, b.end, KompassLink(kind: .block, id: b.id, moduleID: b.moduleID))
        }
        for d in store.deadlines {
            add("\(d.kind.label): \(d.title)", d.date, d.allDay ? d.date : d.date.adding(minutes: max(30, d.durationMinutes)),
                KompassLink(kind: .deadline, id: d.id, moduleID: d.moduleID), allDay: d.allDay)
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Freie Zeit

    /// Belegte Intervalle (Termine aller Kalender + feste Arbeitsblöcke), ohne als „frei“ markierte Termine.
    func busyIntervals(from start: Date, to end: Date, excludingBlocks: Bool = false) -> [DateInterval] {
        var out: [DateInterval] = []
        for e in allEvents(from: start, to: end) where !e.isFree {
            if e.isAllDay { continue }
            if excludingBlocks, e.link?.kind == .block { continue }
            out.append(DateInterval(start: e.start, end: max(e.end, e.start)))
        }
        out.append(contentsOf: workIntervals(from: start, to: end))
        return out.sorted { $0.start < $1.start }
    }

    /// Feste Werkstudenten-Blöcke als konkrete Intervalle.
    func workIntervals(from start: Date, to end: Date) -> [DateInterval] {
        var out: [DateInterval] = []
        var day = start.startOfDay
        while day < end {
            for w in store.workBlocks where w.weekday == day.isoWeekday {
                let s = day.at(minutes: w.startMinutes), e = day.at(minutes: w.endMinutes)
                if e > s { out.append(DateInterval(start: s, end: e)) }
            }
            day = day.adding(days: 1)
        }
        return out
    }

    /// Arbeitszeit in Minuten (feste Blöcke + Termine aus dem Arbeitskalender).
    func workMinutes(from start: Date, to end: Date) -> Int {
        var total = workIntervals(from: start, to: end).reduce(0) { $0 + Int($1.duration / 60) }
        if let wid = store.prefs.workCalendarID, let wc = calendar(wid) {
            total += events(from: start, to: end, calendars: [wc]).filter { !$0.isAllDay }.reduce(0) { $0 + $1.minutes }
        }
        return total
    }
}
