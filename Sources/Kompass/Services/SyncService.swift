import Foundation
import EventKit
import UserNotifications

/// Hält Fristen, Veranstaltungen und Lernblöcke mit Apple Kalender, der Erinnerungen-App
/// und den macOS-Mitteilungen synchron – in beide Richtungen.
@MainActor
final class SyncService {
    private let store: DataStore
    private let calendar: CalendarService
    private let center = UNUserNotificationCenter.current()
    private var notifTask: Task<Void, Never>?
    private var reconciling = false

    init(store: DataStore, calendar: CalendarService) {
        self.store = store
        self.calendar = calendar
    }

    // MARK: Mitteilungen

    func requestNotificationPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Plant alle lokalen Mitteilungen neu (Fristen, Wochenrückblick, Tagesüberblick).
    func rescheduleNotifications() {
        guard !Paths.isDemo else { return }
        notifTask?.cancel()
        notifTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.scheduleAll()
        }
    }

    private func scheduleAll() async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix("dl-") || $0.hasPrefix("weekly-") || $0.hasPrefix("daily-") || $0.hasPrefix("confirm-") }
        center.removePendingNotificationRequests(withIdentifiers: ours)

        let prefs = store.prefs
        let now = Date()
        var requests: [UNNotificationRequest] = []

        if prefs.notifyLocal {
            var items: [(Date, UNNotificationRequest)] = []
            for d in store.deadlines where !d.done && d.date > now {
                let offsets = d.reminderOffsets.isEmpty ? d.kind.defaultOffsets : d.reminderOffsets
                for off in offsets {
                    let fire = d.date.adding(minutes: -off)
                    guard fire > now else { continue }
                    let content = UNMutableNotificationContent()
                    let mod = store.module(d.moduleID)
                    content.title = "\(d.kind.label) in \(Fmt.offsetLabel(off))"
                    content.subtitle = d.title
                    content.body = [mod?.name, Fmt.dateTime(d.date, allDay: d.allDay), d.location.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
                    content.sound = .default
                    content.userInfo = ["deadline": d.id.uuidString]
                    let comps = Calendar.kompass.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    let req = UNNotificationRequest(identifier: "dl-\(d.id.uuidString)-\(off)", content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
                    items.append((fire, req))
                }
            }
            requests += items.sorted { $0.0 < $1.0 }.prefix(48).map(\.1)
        }

        if prefs.weeklyReviewEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Dein Wochenrückblick ist bereit"
            content.body = "Schau, was du diese Woche geschafft hast, und plane die nächste."
            content.sound = .default
            content.userInfo = ["open": "week"]
            var comps = DateComponents()
            comps.weekday = 1 // Sonntag
            comps.hour = prefs.weeklyReviewHour
            comps.minute = 0
            requests.append(UNNotificationRequest(identifier: "weekly-review", content: content,
                                                  trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
        }

        if prefs.dailyBriefingEnabled {
            // Tagesüberblick für die nächsten 7 Tage mit konkretem Inhalt.
            for i in 0..<7 {
                let day = now.startOfDay.adding(days: i)
                let fire = day.at(minutes: prefs.dailyBriefingMinutes)
                guard fire > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Guten Morgen\(prefs.userName.isEmpty ? "" : ", \(prefs.userName)")"
                content.body = briefing(for: day)
                content.userInfo = ["open": "today"]
                let comps = Calendar.kompass.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                requests.append(UNNotificationRequest(identifier: "daily-\(Fmt.machineDay.string(from: day))", content: content,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }

        if prefs.confirmReminderEnabled {
            // Abends erinnern, wenn an dem Tag bestätigbare Termine liegen
            let app = AppModel.shared
            for i in 0..<7 {
                let day = now.startOfDay.adding(days: i)
                let fire = day.at(minutes: prefs.confirmReminderMinutes)
                guard fire > now else { continue }
                let items = app.trackables(from: day, to: fire).filter { !app.isConfirmed($0) && !app.isSkipped($0) }
                guard !items.isEmpty else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Wie war dein Tag?"
                content.body = "\(items.count) Termin\(items.count == 1 ? "" : "e") heute – kurz bestätigen, was du wahrgenommen hast, dann stimmt deine Zeiterfassung."
                content.userInfo = ["open": "time"]
                let comps = Calendar.kompass.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                requests.append(UNNotificationRequest(identifier: "confirm-\(Fmt.machineDay.string(from: day))", content: content,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }

        for r in requests { try? await center.add(r) }
    }

    private func briefing(for day: Date) -> String {
        let blocks = store.blocks.filter { $0.start.isSameDay(day) && $0.status == .planned }
        let due = store.deadlines.filter { !$0.done && $0.date >= day && $0.date < day.adding(days: 3) }
        var parts: [String] = []
        if !blocks.isEmpty {
            let mins = blocks.reduce(0) { $0 + $1.minutes }
            parts.append("\(blocks.count) Lernblock\(blocks.count == 1 ? "" : "e") (\(Fmt.hours(mins)))")
        }
        if let d = due.sorted(by: { $0.date < $1.date }).first {
            parts.append("\(d.kind.label) „\(d.title)“ \(Fmt.relative(d.date, now: day.at(minutes: 8 * 60)))")
        }
        return parts.isEmpty ? "Heute ist nichts Dringendes geplant – guter Tag, um vorzuarbeiten." : parts.joined(separator: " · ")
    }

    func scheduleFocusEnd(at date: Date, moduleName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Fokuszeit geschafft"
        content.body = "\(moduleName): Zeit für eine Pause. Beende den Timer, um die Lernzeit zu speichern."
        content.sound = .default
        let interval = max(1, date.timeIntervalSinceNow)
        center.add(UNNotificationRequest(identifier: "focus-end", content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
    }

    func cancelFocusEnd() {
        center.removePendingNotificationRequests(withIdentifiers: ["focus-end"])
    }

    // MARK: Fristen ↔ Kalender & Erinnerungen

    func sync(deadlineID: UUID) {
        guard var d = store.deadline(deadlineID) else { return }
        let before = d
        syncEvent(&d)
        syncReminder(&d)
        if d != before { store.updateDeadline(d.id) { $0 = d } }
        rescheduleNotifications()
    }

    func remove(deadline d: Deadline) {
        calendar.deleteEvent(identifier: d.eventIdentifier, external: d.eventExternalID)
        calendar.removeReminder(d.reminderIdentifier, external: d.reminderExternalID)
        rescheduleNotifications()
    }

    private func title(for d: Deadline) -> String {
        let code = store.module(d.moduleID)?.displayCode
        return "\(d.kind.label): \(d.title)" + (code.map { " · \($0)" } ?? "")
    }

    private func syncEvent(_ d: inout Deadline) {
        guard calendar.eventsAuthorized else { return }
        let link = KompassLink(kind: .deadline, id: d.id, moduleID: d.moduleID)
        let existing = calendar.findEvent(local: d.eventIdentifier, external: d.eventExternalID)
            ?? calendar.findEvent(link: link, near: d.date)
        let e: EKEvent
        if let existing { e = existing } else {
            guard let cal = calendar.ensureKompassCalendar() else { return }
            e = EKEvent(eventStore: calendar.ek)
            e.calendar = cal
        }
        let offsets = d.reminderOffsets.isEmpty ? d.kind.defaultOffsets : d.reminderOffsets
        var draft = CalendarService.EventDraft(title: title(for: d), start: d.date,
                                               end: d.allDay ? d.date : d.date.adding(minutes: max(d.durationMinutes, 30)))
        draft.allDay = d.allDay
        draft.location = d.location
        draft.notes = d.notes
        draft.link = KompassLink(kind: .deadline, id: d.id, moduleID: d.moduleID)
        draft.alarmMinutes = (store.prefs.useCalendarAlarms && !d.done) ? offsets.filter { $0 <= 3 * 24 * 60 } : []
        calendar.apply(draft, to: e)
        do {
            try calendar.save(e)
            d.eventIdentifier = e.eventIdentifier
            d.eventExternalID = e.calendarItemExternalIdentifier ?? d.eventExternalID
            calendar.markSeen(d.eventExternalID ?? d.eventIdentifier)
        } catch {
            calendar.lastError = error.localizedDescription
        }
    }

    private func syncReminder(_ d: inout Deadline) {
        guard store.prefs.useRemindersApp, calendar.remindersAuthorized else {
            if !store.prefs.useRemindersApp, d.reminderIdentifier != nil || d.reminderExternalID != nil {
                calendar.removeReminder(d.reminderIdentifier, external: d.reminderExternalID)
                d.reminderIdentifier = nil
                d.reminderExternalID = nil
            }
            return
        }
        let r: EKReminder
        if let existing = calendar.findReminder(local: d.reminderIdentifier, external: d.reminderExternalID) { r = existing } else {
            guard let list = calendar.ensureReminderList() else { return }
            r = EKReminder(eventStore: calendar.ek)
            r.calendar = list
        }
        r.title = title(for: d)
        r.notes = [store.module(d.moduleID)?.name, d.location.nilIfEmpty, d.notes.nilIfEmpty].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        var comps = Calendar.kompass.dateComponents(d.allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute], from: d.date)
        comps.timeZone = d.allDay ? nil : TimeZone.current
        r.dueDateComponents = comps
        r.url = KompassLink(kind: .deadline, id: d.id, moduleID: d.moduleID).url
        r.priority = d.kind == .klausur ? 1 : (d.kind == .abgabe ? 5 : 0)
        r.isCompleted = d.done
        let offsets = d.reminderOffsets.isEmpty ? d.kind.defaultOffsets : d.reminderOffsets
        r.alarms = d.done ? nil : offsets.map { EKAlarm(absoluteDate: d.date.adding(minutes: -$0)) }.filter { ($0.absoluteDate ?? .distantPast) > Date() }
        do {
            try calendar.saveReminder(r)
            d.reminderIdentifier = r.calendarItemIdentifier
            d.reminderExternalID = r.calendarItemExternalIdentifier ?? d.reminderExternalID
        } catch {
            calendar.lastError = error.localizedDescription
        }
    }

    // MARK: Veranstaltungen → wiederkehrende Termine

    func syncSessions(moduleID: UUID) {
        guard calendar.eventsAuthorized, let module = store.module(moduleID) else { return }
        let term = store.term(module.termID) ?? store.currentTerm
        var updated = module
        for i in updated.sessions.indices {
            let s = updated.sessions[i]
            let start = firstOccurrence(weekday: s.weekday, from: max(term?.start ?? Date(), Date().startOfWeek))
            let draftTitle = "\(module.displayCode) \(s.kind.short.isEmpty ? s.kind.label : s.kind.short): \(module.name)"
            var draft = CalendarService.EventDraft(title: draftTitle, start: start.at(minutes: s.startMinutes), end: start.at(minutes: s.endMinutes))
            draft.location = s.room
            draft.link = KompassLink(kind: .session, id: s.id, moduleID: module.id)
            let until = term?.lectureEnd ?? term?.end ?? Date().adding(weeks: 16)
            draft.recurrence = EKRecurrenceRule(recurrenceWith: .weekly, interval: s.biweekly ? 2 : 1, end: EKRecurrenceEnd(end: until.endOfDay))
            let sessionLink = KompassLink(kind: .session, id: s.id, moduleID: module.id)
            if let e = calendar.findEvent(local: s.eventIdentifier, external: s.eventExternalID)
                ?? calendar.findEvent(link: sessionLink, near: start, days: 200) {
                updated.sessions[i].eventIdentifier = e.eventIdentifier
                updated.sessions[i].eventExternalID = e.calendarItemExternalIdentifier
                // Bestehende Serie: nur bei Änderung neu schreiben.
                let cur = (e.title ?? "", (e.startDate ?? start).minutesSinceMidnight, (e.endDate ?? start).minutesSinceMidnight, e.location ?? "", (e.startDate ?? start).isoWeekday)
                if cur != (draftTitle, s.startMinutes, s.endMinutes, s.room, s.weekday) {
                    try? calendar.deleteEvent(e, futureEvents: true)
                    if let new = try? calendar.create(draft) {
                        updated.sessions[i].eventIdentifier = new.eventIdentifier
                        updated.sessions[i].eventExternalID = new.calendarItemExternalIdentifier
                    }
                }
            } else if let new = try? calendar.create(draft) {
                updated.sessions[i].eventIdentifier = new.eventIdentifier
                updated.sessions[i].eventExternalID = new.calendarItemExternalIdentifier
            }
        }
        if updated != module { store.updateModule(moduleID) { $0 = updated } }
    }

    func removeSession(_ s: CourseSession) {
        calendar.deleteEvent(identifier: s.eventIdentifier, external: s.eventExternalID, futureEvents: true)
    }

    private func firstOccurrence(weekday: Int, from date: Date) -> Date {
        var d = date.startOfDay
        for _ in 0..<7 {
            if d.isoWeekday == weekday { return d }
            d = d.adding(days: 1)
        }
        return d
    }

    // MARK: Lernblöcke

    func createEvents(for blocks: [PlannedBlock]) -> [PlannedBlock] {
        var out: [PlannedBlock] = []
        for var b in blocks {
            let m = store.module(b.moduleID)
            var draft = CalendarService.EventDraft(title: "Lernen: \(m?.name ?? "Modul")" + (b.focus.isEmpty ? "" : " – \(b.focus)"),
                                                   start: b.start, end: b.end)
            draft.link = KompassLink(kind: .block, id: b.id, moduleID: b.moduleID)
            draft.notes = "Geplant von Kompass. Nach dem Block in Kompass abhaken, damit dein Fortschritt stimmt."
            draft.alarmMinutes = store.prefs.blockAlarmMinutes > 0 ? [store.prefs.blockAlarmMinutes] : []
            if let e = try? calendar.create(draft) {
                b.eventIdentifier = e.eventIdentifier
                b.eventExternalID = e.calendarItemExternalIdentifier
                calendar.markSeen(b.eventExternalID ?? b.eventIdentifier)
            }
            out.append(b)
        }
        return out
    }

    func removeBlock(_ b: PlannedBlock) {
        calendar.deleteEvent(identifier: b.eventIdentifier, external: b.eventExternalID)
        store.blocks.removeAll { $0.id == b.id }
    }

    // MARK: Abgleich nach externen Änderungen (Zwei-Wege-Sync)

    func reconcile() {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }

        // Fristen: In Apple Kalender verschoben → Datum übernehmen; in Erinnerungen abgehakt → erledigt.
        // Nicht gefundene Termine werden NICHT als gelöscht gewertet – sie können auf einem anderen Gerät
        // angelegt und hier noch nicht synchronisiert sein.
        var changedDeadlines = false
        var deadlines = store.deadlines
        for i in deadlines.indices {
            var d = deadlines[i]
            if calendar.eventsAuthorized, let e = calendar.findEvent(local: d.eventIdentifier, external: d.eventExternalID) {
                calendar.markSeen(e.calendarItemExternalIdentifier ?? e.eventIdentifier)
                let start = e.startDate ?? d.date
                if abs(start.timeIntervalSince(d.date)) > 59 && !(d.allDay && start.isSameDay(d.date)) {
                    d.date = d.allDay ? start.startOfDay : start
                }
                if d.eventIdentifier != e.eventIdentifier { d.eventIdentifier = e.eventIdentifier }
                if d.eventExternalID == nil, let ext = e.calendarItemExternalIdentifier { d.eventExternalID = ext }
            }
            if let r = calendar.findReminder(local: d.reminderIdentifier, external: d.reminderExternalID), r.isCompleted != d.done {
                d.done = r.isCompleted
                d.doneAt = r.isCompleted ? (r.completionDate ?? Date()) : nil
            }
            if d != deadlines[i] { deadlines[i] = d; changedDeadlines = true }
        }
        if changedDeadlines { store.deadlines = deadlines }

        // Lernblöcke: verschoben → Zeiten übernehmen; gelöscht (und auf diesem Gerät schon gesehen) → aus dem Plan entfernen.
        guard calendar.eventsAuthorized else { return }
        var blocks = store.blocks
        var changedBlocks = false
        blocks.removeAll { b in
            guard b.status == .planned, b.eventIdentifier != nil || b.eventExternalID != nil else { return false }
            if calendar.findEvent(local: b.eventIdentifier, external: b.eventExternalID) != nil { return false }
            let key = b.eventExternalID ?? b.eventIdentifier
            if calendar.wasSeen(key) { changedBlocks = true; return true }
            return false
        }
        for i in blocks.indices {
            guard let e = calendar.findEvent(local: blocks[i].eventIdentifier, external: blocks[i].eventExternalID) else { continue }
            calendar.markSeen(e.calendarItemExternalIdentifier ?? e.eventIdentifier)
            if e.startDate != blocks[i].start || e.endDate != blocks[i].end {
                blocks[i].start = e.startDate
                blocks[i].end = e.endDate
                changedBlocks = true
            }
            if blocks[i].eventExternalID == nil, let ext = e.calendarItemExternalIdentifier { blocks[i].eventExternalID = ext; changedBlocks = true }
        }
        if changedBlocks { store.blocks = blocks }
    }

    /// Beim Start: alles sicherstellen (fehlende Termine/Erinnerungen anlegen).
    func resyncAll() {
        // Nur Fristen, die noch nie (auf keinem Gerät) eingetragen wurden – sonst drohen Duplikate.
        for d in store.deadlines where !d.done && d.date > Date().adding(days: -1) {
            let neverInCalendar = d.eventIdentifier == nil && d.eventExternalID == nil
            let neverInReminders = store.prefs.useRemindersApp && d.reminderIdentifier == nil && d.reminderExternalID == nil
            if neverInCalendar || neverInReminders {
                sync(deadlineID: d.id)
            }
        }
        rescheduleNotifications()
    }
}
