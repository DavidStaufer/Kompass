import Foundation

/// Verteilt Lernzeit automatisch auf freie Slots – um Vorlesungen, Arbeit und private Termine herum.
@MainActor
struct Planner {
    let store: DataStore
    let calendar: CalendarService

    struct Demand: Identifiable {
        let id: UUID
        var minutes: Int
        var reason: String
        var cutoff: Date?
    }

    /// Freie Intervalle innerhalb der Lernzeiten, abzüglich Termine, Arbeitsblöcke und Puffer.
    func freeSlots(from: Date, to: Date, ignoringBlocks: Bool = false) -> [DateInterval] {
        let p = store.prefs
        let buffer = Double(p.bufferMinutes) * 60
        let busy = calendar.busyIntervals(from: from.startOfDay, to: to.endOfDay, excludingBlocks: ignoringBlocks)
            .map { DateInterval(start: $0.start.addingTimeInterval(-buffer), end: $0.end.addingTimeInterval(buffer)) }
        var result: [DateInterval] = []
        var day = from.startOfDay
        while day < to {
            if day.isWeekend && !p.studyOnWeekends { day = day.adding(days: 1); continue }
            let winStart = max(day.at(minutes: p.studyDayStart), from)
            let winEnd = min(day.at(minutes: p.studyDayEnd), to)
            if winEnd > winStart {
                var cursor = winStart
                for b in busy where b.end > winStart && b.start < winEnd {
                    if b.start > cursor { result.append(DateInterval(start: cursor, end: b.start)) }
                    cursor = max(cursor, b.end)
                }
                if winEnd > cursor { result.append(DateInterval(start: cursor, end: winEnd)) }
            }
            day = day.adding(days: 1)
        }
        return result.filter { $0.duration >= 15 * 60 }
    }

    /// Wie viel Lernzeit braucht jedes Modul in dieser Woche?
    func demands(weekStart: Date) -> [Demand] {
        let weekEnd = weekStart.adding(days: 7)
        let now = Date()
        var out: [Demand] = []
        for m in store.activeModules {
            var minutes = m.weeklyGoalHours * 60
            var reasons = ["Wochenziel \(Fmt.hours(Int(m.weeklyGoalHours * 60)))"]
            var cutoff: Date?
            if let exam = store.nextExam(for: m.id, after: weekStart) {
                let days = weekStart.daysUntil(exam.date)
                if days <= 35 {
                    let factor = 1 + 2 * Double(35 - max(0, days)) / 35
                    minutes *= factor
                    reasons.append("Klausur \(Fmt.relative(exam.date, now: weekStart))")
                }
                if exam.date < weekEnd { cutoff = exam.date }
            } else if let last = store.deadlines.filter({ $0.moduleID == m.id && $0.kind == .klausur }).map(\.date).max(), last < weekStart {
                // Klausur schon geschrieben → kein Lernbedarf mehr
                minutes = 0
            }
            // Abgaben/Präsentationen in dieser oder Anfang nächster Woche
            for d in store.deadlines where d.moduleID == m.id && !d.done && d.kind != .klausur && d.date >= weekStart && d.date < weekEnd.adding(days: 3) {
                minutes += d.effectivePrepHours * 60 * (d.date < weekEnd ? 1 : 0.5)
                reasons.append("\(d.kind.label) \(Fmt.relative(d.date, now: weekStart))")
                if d.date < weekEnd { cutoff = min(cutoff ?? d.date, d.date) }
            }
            let logged = store.minutes(moduleID: m.id, from: weekStart, to: weekEnd)
            let alreadyPlanned = store.blocks.filter { $0.moduleID == m.id && $0.start >= max(weekStart, now) && $0.start < weekEnd && $0.status == .planned }
                .reduce(0) { $0 + $1.minutes }
            let remaining = Int(minutes) - logged - alreadyPlanned
            if remaining >= 30 {
                out.append(Demand(id: m.id, minutes: remaining, reason: reasons.joined(separator: " · "), cutoff: cutoff))
            }
        }
        return out.sorted { $0.minutes > $1.minutes }
    }

    /// Erstellt einen Vorschlag (noch nicht im Kalender).
    func propose(weekStart: Date) -> [PlannedBlock] {
        let p = store.prefs
        let from = max(weekStart, Date().adding(minutes: 15))
        let to = weekStart.adding(days: 7)
        var demands = demands(weekStart: weekStart)
        guard !demands.isEmpty else { return [] }

        // Freie Slots in Blöcke schneiden
        var candidates: [DateInterval] = []
        for slot in freeSlots(from: from, to: to) {
            var cursor = roundUp(slot.start)
            while true {
                let remaining = Int(slot.end.timeIntervalSince(cursor) / 60)
                if remaining < p.minBlockMinutes { break }
                var len = min(p.blockMinutes, remaining)
                if remaining - len < p.minBlockMinutes && remaining <= Int(Double(p.blockMinutes) * 1.4) { len = remaining }
                let end = cursor.adding(minutes: len)
                candidates.append(DateInterval(start: cursor, end: end))
                cursor = roundUp(end.adding(minutes: p.breakMinutes))
            }
        }

        var perDay: [Date: Int] = [:]
        for b in store.blocks where b.start >= weekStart && b.start < to && b.status != .missed {
            perDay[b.start.startOfDay, default: 0] += b.minutes
        }
        var out: [PlannedBlock] = []
        var lastModuleByDay: [Date: UUID] = [:]
        var topicsCursor: [UUID: Int] = [:]

        for c in candidates {
            let day = c.start.startOfDay
            let cap = day.isWeekend ? min(p.weekendMaxMinutes, p.maxStudyMinutesPerDay) : p.maxStudyMinutesPerDay
            let minutes = Int(c.duration / 60)
            guard perDay[day, default: 0] + minutes <= cap else { continue }
            if p.protectedEvenings && c.start.minutesSinceMidnight >= 19 * 60 { continue }

            let eligible = demands.indices.filter { i in
                demands[i].minutes > 0 && (demands[i].cutoff.map { c.end <= $0 } ?? true)
            }
            guard !eligible.isEmpty else { continue }
            // Dringlichkeit: verbleibender Bedarf, Fristen zuerst; nicht zweimal hintereinander dasselbe Modul
            let ranked = eligible.sorted { a, b in
                let ua = Double(demands[a].minutes) * (demands[a].cutoff != nil ? 1.6 : 1)
                let ub = Double(demands[b].minutes) * (demands[b].cutoff != nil ? 1.6 : 1)
                return ua > ub
            }
            var pick = ranked[0]
            if demands[pick].id == lastModuleByDay[day], ranked.count > 1 { pick = ranked[1] }

            let moduleID = demands[pick].id
            let focus = nextFocus(moduleID: moduleID, cursor: &topicsCursor)
            out.append(PlannedBlock(moduleID: moduleID, start: c.start, end: c.end, focus: focus))
            demands[pick].minutes -= minutes
            perDay[day, default: 0] += minutes
            lastModuleByDay[day] = moduleID
            if demands.allSatisfy({ $0.minutes <= 0 }) { break }
        }
        return out
    }

    /// Schwächste, bereits behandelte Themen zuerst.
    private func nextFocus(moduleID: UUID, cursor: inout [UUID: Int]) -> String {
        guard let m = store.module(moduleID), !m.topics.isEmpty else { return "" }
        let sorted = m.topics.sorted { a, b in
            if a.covered != b.covered { return a.covered }
            return a.confidence < b.confidence
        }.filter { $0.confidence < 0.9 }
        guard !sorted.isEmpty else { return "Wiederholung" }
        let i = cursor[moduleID, default: 0] % sorted.count
        cursor[moduleID] = i + 1
        return sorted[i].title
    }

    private func roundUp(_ d: Date) -> Date {
        let m = d.minutesSinceMidnight
        let r = (m + 14) / 15 * 15
        return d.startOfDay.at(minutes: r)
    }

    /// Übernimmt einen Vorschlag in den Kalender.
    func commit(_ blocks: [PlannedBlock], sync: SyncService) -> [PlannedBlock] {
        let saved = sync.createEvents(for: blocks)
        store.blocks.append(contentsOf: saved)
        return saved
    }
}
