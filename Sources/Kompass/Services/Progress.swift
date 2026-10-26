import Foundation
import SwiftUI

struct ModuleProgress {
    enum Status {
        case onTrack, behind, critical, noExam, done
        var label: String {
            switch self {
            case .onTrack: return "Im Plan"
            case .behind: return "Etwas hinterher"
            case .critical: return "Dringend aufholen"
            case .noExam: return "Kein Klausurtermin"
            case .done: return "Abgeschlossen"
            }
        }
        var color: Color {
            switch self {
            case .onTrack: return .green
            case .behind: return .orange
            case .critical: return .red
            case .noExam: return .secondary
            case .done: return .blue
            }
        }
        var symbol: String {
            switch self {
            case .onTrack: return "checkmark.circle.fill"
            case .behind: return "exclamationmark.circle.fill"
            case .critical: return "exclamationmark.triangle.fill"
            case .noExam: return "calendar.badge.exclamationmark"
            case .done: return "flag.checkered"
            }
        }
    }

    var topicConfidence: Double?
    var topicsCovered = 0
    var topicsTotal = 0
    var materialsStudied = 0
    var materialsTotal = 0
    var quizAverage: Double?
    var cardsMature = 0
    var cardsTotal = 0
    var minutesThisWeek = 0
    var goalMinutesWeek = 0
    var minutesTotal = 0
    var targetMinutesTotal = 0
    var expected: Double = 0
    var overall: Double = 0
    var examDate: Date?
    var status: Status = .noExam

    var timeRatio: Double { targetMinutesTotal > 0 ? min(1, Double(minutesTotal) / Double(targetMinutesTotal)) : 0 }
    var weekRatio: Double { goalMinutesWeek > 0 ? min(1, Double(minutesThisWeek) / Double(goalMinutesWeek)) : 0 }
}

@MainActor
enum ProgressEngine {
    static func progress(for m: Module, store: DataStore, now: Date = Date()) -> ModuleProgress {
        var p = ModuleProgress()
        p.topicsTotal = m.topics.count
        p.topicsCovered = m.topics.filter(\.covered).count
        if !m.topics.isEmpty { p.topicConfidence = m.topics.map(\.confidence).reduce(0, +) / Double(m.topics.count) }
        let mats = m.materials.filter { $0.kind != .loesung && $0.kind != .notiz }
        p.materialsTotal = mats.count
        p.materialsStudied = mats.filter(\.studied).count

        let attempts = store.quizzes.filter { $0.moduleID == m.id }.flatMap(\.attempts).sorted { $0.date < $1.date }.suffix(6)
        if !attempts.isEmpty { p.quizAverage = attempts.map(\.score).reduce(0, +) / Double(attempts.count) }
        let cards = store.flashcards.filter { $0.moduleID == m.id }
        p.cardsTotal = cards.count
        p.cardsMature = cards.filter(\.isMature).count

        let week = now.startOfWeek
        p.minutesThisWeek = store.minutes(moduleID: m.id, from: week, to: week.adding(days: 7))
        p.goalMinutesWeek = Int(m.weeklyGoalHours * 60)
        p.minutesTotal = store.minutes(moduleID: m.id, from: .distantPast, to: .distantFuture)

        let term = store.term(m.termID) ?? store.currentTerm
        let exam = store.nextExam(for: m.id, after: now.adding(days: -1))
        p.examDate = exam?.date
        let start = term?.start ?? m.createdAt
        let end = exam?.date ?? term?.end ?? now.adding(weeks: 12)
        let weeks = max(1, end.timeIntervalSince(start) / (7 * 86400))
        p.targetMinutesTotal = Int(weeks * m.weeklyGoalHours * 60)

        // Gesamtfortschritt aus allen vorhandenen Signalen
        var parts: [(Double, Double)] = []
        if let c = p.topicConfidence { parts.append((c, 0.35)) }
        if p.materialsTotal > 0 { parts.append((Double(p.materialsStudied) / Double(p.materialsTotal), 0.2)) }
        var practice: [Double] = []
        if let q = p.quizAverage { practice.append(q) }
        if p.cardsTotal > 0 { practice.append(Double(p.cardsMature) / Double(p.cardsTotal)) }
        if !practice.isEmpty { parts.append((practice.reduce(0, +) / Double(practice.count), 0.25)) }
        parts.append((p.timeRatio, 0.2))
        let wsum = parts.reduce(0) { $0 + $1.1 }
        p.overall = wsum > 0 ? parts.reduce(0) { $0 + $1.0 * $1.1 } / wsum : 0

        let pastExams = store.deadlines.filter { $0.moduleID == m.id && $0.kind == .klausur && $0.date < now }
        if exam == nil && !pastExams.isEmpty {
            p.status = .done
        } else if let exam {
            let total = exam.date.timeIntervalSince(start)
            p.expected = total > 0 ? min(1, max(0, now.timeIntervalSince(start) / total)) : 1
            let gap = p.expected - p.overall
            let daysLeft = now.daysUntil(exam.date)
            if gap <= 0.1 { p.status = .onTrack }
            else if gap <= 0.25 && daysLeft > 7 { p.status = .behind }
            else { p.status = .critical }
        } else {
            p.status = .noExam
            if let term {
                let total = term.end.timeIntervalSince(term.start)
                p.expected = total > 0 ? min(1, max(0, now.timeIntervalSince(term.start) / total)) : 0
            }
        }
        return p
    }
}

/// Was sollte diese Woche geschafft werden – und was wurde geschafft?
struct WeekReport {
    struct ModuleLine: Identifiable {
        let id: UUID
        let name: String
        let color: Color
        var goal: Int
        var logged: Int
        var planned: Int
        var blocksPlanned: Int
        var blocksDone: Int
    }

    let weekStart: Date
    var lines: [ModuleLine] = []
    var tasksDue: [TaskItem] = []
    var tasksDone: [TaskItem] = []
    var deadlines: [Deadline] = []
    var totalGoal = 0
    var totalLogged = 0
    var workMinutes = 0
    var workLogged = 0
    var otherLogged = 0
    var lectureMinutes = 0
    var eventMinutes = 0
    var freeMinutes = 0
    var quizzesTaken = 0
    var cardsReviewed = 0

    var completion: Double { totalGoal > 0 ? min(1, Double(totalLogged) / Double(totalGoal)) : 0 }

    @MainActor
    static func make(weekStart: Date, store: DataStore, calendar: CalendarService, includeFree: Bool = false) -> WeekReport {
        let end = weekStart.adding(days: 7)
        var r = WeekReport(weekStart: weekStart)
        for m in store.activeModules {
            let bl = store.blocks.filter { $0.moduleID == m.id && $0.start >= weekStart && $0.start < end }
            let line = ModuleLine(id: m.id, name: m.name, color: m.color.color,
                                  goal: Int(m.weeklyGoalHours * 60),
                                  logged: store.minutes(moduleID: m.id, from: weekStart, to: end),
                                  planned: bl.reduce(0) { $0 + $1.minutes },
                                  blocksPlanned: bl.count,
                                  blocksDone: bl.filter { $0.status == .done || $0.status == .partial }.count)
            r.lines.append(line)
        }
        r.totalGoal = r.lines.reduce(0) { $0 + $1.goal }
        r.totalLogged = r.lines.reduce(0) { $0 + $1.logged }
        r.tasksDue = store.tasks.filter { t in (t.due.map { $0 >= weekStart && $0 < end } ?? false) }
        r.tasksDone = store.tasks.filter { t in t.done && (t.doneAt.map { $0 >= weekStart && $0 < end } ?? false) }
        r.deadlines = store.deadlines.filter { $0.date >= weekStart && $0.date < end }.sorted { $0.date < $1.date }
        r.quizzesTaken = store.quizzes.flatMap(\.attempts).filter { $0.date >= weekStart && $0.date < end }.count

        let events = calendar.allEvents(from: weekStart, to: end).filter { !$0.isAllDay && !$0.isFree }
        r.lectureMinutes = events.filter { $0.link?.kind == .session }.reduce(0) { $0 + $1.minutes }
        r.eventMinutes = events.filter { $0.link == nil }.reduce(0) { $0 + $1.minutes }
        r.workMinutes = calendar.workMinutes(from: weekStart, to: end)
        r.workLogged = store.loggedMinutes(from: weekStart, to: end) { $0.kind == .work }
        r.otherLogged = store.loggedMinutes(from: weekStart, to: end) { $0.kind == .custom }
        if includeFree {
            let planner = Planner(store: store, calendar: calendar)
            r.freeMinutes = planner.freeSlots(from: max(weekStart, Date()), to: end, ignoringBlocks: true)
                .reduce(0) { $0 + Int($1.duration / 60) }
        }
        return r
    }
}
