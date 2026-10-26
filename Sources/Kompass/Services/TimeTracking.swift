import Foundation
import SwiftUI

/// Ein Termin-Vorkommen, das als „wahrgenommen“ bestätigt werden kann.
struct TrackItem: Identifiable, Hashable {
    let key: String
    let title: String
    let start: Date
    let end: Date
    var target: TrackTarget
    var activity: ActivityKind
    var blockID: UUID?
    var deadlineID: UUID?
    var source: LogSource
    /// Privater Termin ohne gemerkte Kategorie – muss beim Bestätigen zugeordnet werden.
    var needsCategory: Bool
    /// Fristen wie Abgaben sind Zeitpunkte, keine Termine, die man „wahrnimmt“.
    var attendable = true

    var id: String { key }
    var minutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }
    var hasStarted: Bool { start <= Date() }
}

@MainActor
extension AppModel {
    // MARK: Termine → bestätigbare Einträge

    func trackItem(for e: CalEvent) -> TrackItem {
        var item = TrackItem(key: e.id, title: e.title, start: e.start, end: e.end, target: TrackTarget(kind: .custom),
                             activity: .sonstiges, source: .calendar, needsCategory: false)
        if let link = e.link {
            switch link.kind {
            case .block:
                if let m = link.moduleID { item.target = .module(m) }
                item.activity = .lernen
                item.blockID = link.id
                item.source = .block
                return item
            case .session:
                if let m = link.moduleID {
                    item.target = .module(m)
                    let kind = store.module(m)?.sessions.first { $0.id == link.id }?.kind ?? .vorlesung
                    item.activity = ActivityKind.from(kind)
                    return item
                }
            case .deadline:
                let d = store.deadline(link.id)
                item.deadlineID = link.id
                if let k = d?.kind, [.abgabe, .anmeldung, .sonstiges].contains(k) || d?.allDay == true {
                    item.attendable = false
                    return item
                }
                if let m = link.moduleID ?? d?.moduleID {
                    item.target = .module(m)
                    switch d?.kind {
                    case .klausur, .testat: item.activity = .pruefung
                    case .praesentation: item.activity = .seminar
                    default: item.activity = .lernen
                    }
                    return item
                }
            case .event, .module:
                if let m = link.moduleID {
                    item.target = .module(m)
                    item.activity = .lernen
                    return item
                }
            }
        }
        if let wid = store.prefs.workCalendarID, e.calendarID == wid {
            item.target = .work
            item.activity = .arbeit
            return item
        }
        if let r = store.rule(forTitle: e.title) {
            item.target = TrackTarget(kind: r.kind, moduleID: r.moduleID, categoryID: r.categoryID)
            item.activity = r.activity
            return item
        }
        item.needsCategory = true
        return item
    }

    func trackItem(for w: WorkBlock, on day: Date) -> TrackItem {
        TrackItem(key: "work|\(w.id.uuidString)|\(Fmt.machineDay.string(from: day))", title: w.label,
                  start: day.at(minutes: w.startMinutes), end: day.at(minutes: w.endMinutes), target: .work,
                  activity: .arbeit, source: .workBlock, needsCategory: false)
    }

    /// Alle zuordenbaren Termine im Zeitraum (Kompass-Termine, Arbeit, gemerkte private Termine).
    func trackables(from: Date, to: Date) -> [TrackItem] {
        var out = calendar.allEvents(from: from, to: to)
            .filter { !$0.isAllDay && $0.minutes > 0 && $0.minutes <= 14 * 60 }
            .map(trackItem(for:))
            .filter { !$0.needsCategory && $0.attendable }
        var day = from.startOfDay
        while day < to {
            for w in store.workBlocks where w.weekday == day.isoWeekday {
                let item = trackItem(for: w, on: day)
                if item.start >= from && item.start < to { out.append(item) }
            }
            day = day.adding(days: 1)
        }
        // Lernblöcke, die (noch) nicht im Kalender stehen
        let blocksInCalendar = Set(out.compactMap(\.blockID))
        for b in store.blocks where b.start >= from && b.start < to && !blocksInCalendar.contains(b.id) {
            out.append(TrackItem(key: "block|\(b.id.uuidString)", title: "Lernen: \(store.module(b.moduleID)?.name ?? "")",
                                 start: b.start, end: b.end, target: .module(b.moduleID), activity: .lernen,
                                 blockID: b.id, source: .block, needsCategory: false))
        }
        var seen = Set<String>()
        var seenBlocks = Set<UUID>()
        return out.filter { i in
            guard seen.insert(i.key).inserted else { return false }
            if let b = i.blockID { return seenBlocks.insert(b).inserted }
            return true
        }.sorted { $0.start < $1.start }
    }

    func isConfirmed(_ item: TrackItem) -> Bool {
        if confirmedLog(for: item) != nil { return true }
        // Lernblock bereits als erledigt markiert (z. B. per Timer oder früherer Abfrage)
        if let bid = item.blockID, let b = store.blocks.first(where: { $0.id == bid }), b.status == .done || b.status == .partial { return true }
        return false
    }

    func confirmedLog(for item: TrackItem) -> Worklog? {
        if let w = store.worklog(eventKey: item.key) { return w }
        if let bid = item.blockID { return store.worklogs.first { $0.blockID == bid } }
        return nil
    }

    func isSkipped(_ item: TrackItem) -> Bool {
        if store.skipped[item.key] != nil { return true }
        if let bid = item.blockID, let b = store.blocks.first(where: { $0.id == bid }), b.status == .missed { return true }
        return false
    }

    /// Vergangene, noch nicht bestätigte Einträge.
    func pendingConfirmations(days: Int = 7) -> [TrackItem] {
        let now = Date()
        return trackables(from: now.startOfDay.adding(days: -(days - 1)), to: now)
            .filter { $0.end <= now && !isConfirmed($0) && !isSkipped($0) }
    }

    // MARK: Bestätigen

    @discardableResult
    func confirm(_ item: TrackItem, target: TrackTarget? = nil, activity: ActivityKind? = nil, minutes: Int? = nil,
                 start: Date? = nil, note: String = "", remember: Bool = false) -> Worklog? {
        if let existing = confirmedLog(for: item) { return existing }
        let t = target ?? item.target
        let a = activity ?? item.activity
        if remember && item.source == .calendar { store.remember(title: item.title, target: t, activity: a) }
        let mins = minutes ?? item.minutes
        if let bid = item.blockID, let i = store.blocks.firstIndex(where: { $0.id == bid }) {
            store.blocks[i].status = mins >= store.blocks[i].minutes / 2 ? .done : .partial
        }
        store.skipped[item.key] = nil
        return store.logWork(t, activity: a, start: start ?? item.start, minutes: mins, source: item.source,
                             note: note, title: item.title, deadlineID: item.deadlineID, blockID: item.blockID, eventKey: item.key)
    }

    func unconfirm(_ item: TrackItem) {
        store.worklogs.removeAll { $0.eventKey == item.key || (item.blockID != nil && $0.blockID == item.blockID) }
        store.skipped[item.key] = nil
        if let bid = item.blockID, let i = store.blocks.firstIndex(where: { $0.id == bid }) { store.blocks[i].status = .planned }
    }

    func skip(_ item: TrackItem) {
        if let bid = item.blockID, let i = store.blocks.firstIndex(where: { $0.id == bid }) { store.blocks[i].status = .missed }
        store.worklogs.removeAll { $0.eventKey == item.key }
        store.skipped[item.key] = item.start
        // Alte Einträge aufräumen (älter als 120 Tage)
        let limit = Date().adding(days: -120)
        if store.skipped.count > 400 { store.skipped = store.skipped.filter { $0.value > limit } }
    }

    @discardableResult
    func confirmAll(_ items: [TrackItem]) -> Int {
        var n = 0
        for i in items where !isConfirmed(i) && i.hasStarted && !i.needsCategory {
            if confirm(i) != nil { n += 1 }
        }
        return n
    }

    // MARK: Lernblöcke (Abfrage „geschafft?“)

    func setBlockStatus(_ id: UUID, _ status: BlockStatus) {
        guard let i = store.blocks.firstIndex(where: { $0.id == id }) else { return }
        let b = store.blocks[i]
        store.blocks[i].status = status
        store.worklogs.removeAll { $0.blockID == b.id }
        let minutes = status == .done ? b.minutes : (status == .partial ? b.minutes / 2 : 0)
        if minutes > 0 {
            store.logWork(.module(b.moduleID), activity: .lernen, start: b.start, minutes: minutes, source: .block,
                          title: b.focus.isEmpty ? "Lernblock" : b.focus, blockID: b.id)
        }
    }

    /// Lernblöcke, die vorbei sind, aber noch nicht bewertet wurden.
    var blocksAwaitingCheckIn: [PlannedBlock] {
        let now = Date()
        return store.blocks.filter { $0.status == .planned && $0.end <= now && $0.end > now.adding(days: -7) }
            .sorted { $0.start < $1.start }
    }

    // MARK: Auswertung

    /// Arbeitsstunden je Kalenderwoche (für die Werkstudenten-Grenze).
    func workMinutesByWeek(from: Date, to: Date) -> [(week: Date, minutes: Int)] {
        var out: [(Date, Int)] = []
        var w = from.startOfWeek
        while w < to {
            out.append((w, store.loggedMinutes(from: w, to: w.adding(days: 7)) { $0.kind == .work }))
            w = w.adding(weeks: 1)
        }
        return out
    }

    /// Prüft, ob eine Woche in der Vorlesungszeit liegt (für die 20-h-Regel).
    func isLectureWeek(_ week: Date) -> Bool {
        guard store.prefs.workLimitLectureOnly else { return true }
        guard let t = store.terms.first(where: { $0.contains(week) || $0.contains(week.adding(days: 6)) }) else { return true }
        return week < (t.lectureEnd ?? t.end)
    }
}
