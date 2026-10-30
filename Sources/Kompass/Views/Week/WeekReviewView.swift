import SwiftUI
import Charts

struct WeekReviewView: View {
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @State private var weekStart = WeekReviewView.defaultWeek

    /// Sonntags und Montagmorgens zeigt der Rückblick die zu Ende gehende Woche.
    static var defaultWeek: Date {
        let now = Date()
        if now.isoWeekday == 1 && now.minutesSinceMidnight < 12 * 60 { return now.startOfWeek.adding(weeks: -1) }
        return now.startOfWeek
    }

    var body: some View {
        let r = WeekReport.make(weekStart: weekStart, store: store, calendar: calendar, includeFree: true)
        let nextStart = weekStart.adding(weeks: 1)
        let next = WeekReport.make(weekStart: nextStart, store: store, calendar: calendar, includeFree: true)

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Wochenplan", subtitle: "KW \(weekStart.weekNumber) · \(Fmt.weekRange(weekStart))") {
                    HStack(spacing: 2) {
                        Button { withAnimation(Motion.standard) { weekStart = weekStart.adding(weeks: -1) } } label: {
                            Label("Vorige Woche", systemImage: "chevron.left").labelStyle(.iconOnly)
                        }
                        .help("Vorige Woche")
                        Button("Diese Woche") { withAnimation(Motion.standard) { weekStart = Date().startOfWeek } }
                        Button { withAnimation(Motion.standard) { weekStart = weekStart.adding(weeks: 1) } } label: {
                            Label("Nächste Woche", systemImage: "chevron.right").labelStyle(.iconOnly)
                        }
                        .help("Nächste Woche")
                    }
                }

                WeekSummaryRow(report: r)

                // Karten als eigene Views: Das Fazit streamt, ohne dass die Berichte neu berechnet werden.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) { WeekGoalsCard(report: r); WeekShouldCard(report: r) }.frame(minWidth: 400)
                        VStack(spacing: 20) {
                            WeekLoadCard(report: r)
                            WeekReflectionCard(report: r, next: next).id(weekStart)
                        }
                        .frame(width: 340)
                    }
                    VStack(spacing: 20) {
                        WeekGoalsCard(report: r); WeekShouldCard(report: r); WeekLoadCard(report: r)
                        WeekReflectionCard(report: r, next: next).id(weekStart)
                    }
                }

                WeekOutlookCard(next: next)
            }
            .pagePadding()
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Wochenplan")
        .inlineNavigationTitle()
    }
}

// MARK: Zusammenfassung

private struct WeekSummaryRow: View {
    let report: WeekReport

    var body: some View {
        let r = report
        let blocksPlanned = r.lines.reduce(0) { $0 + $1.blocksPlanned }
        let blocksDone = r.lines.reduce(0) { $0 + $1.blocksDone }
        let deadlinesDone = r.deadlines.filter(\.done).count
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            StatTile(value: Fmt.hours(r.totalLogged), label: "gelernt", detail: "Ziel \(Fmt.hours(r.totalGoal))", progress: r.completion, color: .accentColor)
            StatTile(value: "\(blocksDone)/\(blocksPlanned)", label: "Lernblöcke", detail: "erledigt", progress: blocksPlanned > 0 ? Double(blocksDone) / Double(blocksPlanned) : nil, color: .green)
            StatTile(value: "\(r.tasksDone.count)", label: "Aufgaben", detail: "\(r.tasksDue.filter { !$0.done }.count) noch offen", progress: nil, color: .orange)
            StatTile(value: "\(deadlinesDone)/\(r.deadlines.count)", label: "Fristen", detail: "diese Woche", progress: r.deadlines.isEmpty ? nil : Double(deadlinesDone) / Double(r.deadlines.count), color: .purple)
        }
    }
}

// MARK: Ziele je Modul

private struct WeekGoalsCard: View {
    let report: WeekReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Geschafft je Modul", symbol: "chart.bar")
            if report.lines.isEmpty {
                Text("Noch keine Module.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(report.lines) { l in
                        BarMark(x: .value("Stunden", Double(l.logged) / 60), y: .value("Modul", l.name))
                            .foregroundStyle(l.color)
                            .cornerRadius(4)
                            .annotation(position: .trailing) {
                                Text("\(Fmt.hours(l.logged)) / \(Fmt.hours(l.goal))").font(.caption2).foregroundStyle(.secondary)
                            }
                            .accessibilityLabel(l.name)
                            .accessibilityValue("\(Fmt.hours(l.logged)) von \(Fmt.hours(l.goal))")
                        PointMark(x: .value("Ziel", Double(l.goal) / 60), y: .value("Modul", l.name))
                            .symbol {
                                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.6)).frame(width: 2.5, height: 20)
                            }
                            .accessibilityHidden(true)
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel() } }
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(1, report.lines.count)) * 34 + 24)
                Text("Strich = Wochenziel").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .card()
    }
}

// MARK: Soll

private struct WeekShouldCard: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    let report: WeekReport

    var body: some View {
        let r = report
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Was diese Woche geschafft sein sollte", symbol: "target")
            if r.deadlines.isEmpty && r.tasksDue.isEmpty {
                Text("Keine Fristen oder fälligen Aufgaben in dieser Woche.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(r.deadlines) { d in
                CheckLine(done: d.done, title: "\(d.kind.label): \(d.title)", detail: "\(Fmt.dayShort(d.date))\(store.module(d.moduleID).map { " · \($0.name)" } ?? "")", tint: d.kind.tint) {
                    app.toggleDeadline(d.id)
                }
            }
            ForEach(r.tasksDue) { t in
                CheckLine(done: t.done, title: t.title, detail: t.due.map { Fmt.dayShort($0) } ?? "", tint: store.color(for: t.moduleID)) {
                    store.toggleTask(t.id)
                }
            }
            let behind = r.lines.filter { $0.goal > 0 && $0.logged < $0.goal }
            if !behind.isEmpty && r.weekStart <= Date() {
                Divider()
                ForEach(behind) { l in
                    HStack {
                        ModuleDot(color: l.color)
                        Text(l.name).font(.callout)
                        Spacer()
                        Text("noch \(Fmt.hours(l.goal - l.logged))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .card()
    }
}

// MARK: Belastung

private struct WeekLoadCard: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    let report: WeekReport

    var body: some View {
        let r = report
        let items: [(String, Int, Color)] = [
            ("Arbeit", r.workMinutes, .gray), ("Vorlesungen & Übungen", r.lectureMinutes, .blue),
            ("Andere Termine", r.eventMinutes, .purple), ("Gelernt", r.totalLogged, .green)
        ]
        let limit = Int(store.prefs.workWeeklyLimitHours * 60)
        let total = max(1, items.reduce(0) { $0 + $1.1 })
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Zeitbudget", symbol: "clock")
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(items.filter { $0.1 > 0 }, id: \.0) { it in
                        RoundedRectangle(cornerRadius: 3).fill(it.2.gradient)
                            .frame(width: max(4, (geo.size.width - 8) * CGFloat(it.1) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            ForEach(items, id: \.0) { it in
                HStack {
                    Circle().fill(it.2).frame(width: 7, height: 7)
                    Text(it.0).font(.callout)
                    Spacer()
                    Text(Fmt.hours(it.1)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if r.workLogged > 0 || r.otherLogged > 0 {
                Divider()
                Button { app.selection = .time } label: {
                    HStack {
                        Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("Arbeit erfasst").font(.callout)
                        Spacer()
                        Text(Fmt.hours(r.workLogged)).font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(limit > 0 && r.workLogged > limit && app.isLectureWeek(r.weekStart) ? .orange : .primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Zeiten öffnen")
            }
            if r.freeMinutes > 0 {
                Divider()
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Noch frei im Lernfenster").font(.callout)
                    Spacer()
                    Text(Fmt.hours(r.freeMinutes)).font(.callout.monospacedDigit().weight(.semibold))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

// MARK: Fazit

/// Eigener Zustand: Beim Streamen des Fazits zeichnet nur diese Karte neu.
private struct WeekReflectionCard: View {
    @Environment(DataStore.self) private var store
    let report: WeekReport
    let next: WeekReport
    @State private var reflection = ""
    @State private var generating = false
    @State private var reflectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Wochenfazit", symbol: "text.quote") {
                if generating { ProgressView().controlSize(.small) }
            }
            if reflection.isEmpty && !generating {
                Text("Lass dir von der KI ein ehrliches Fazit mit konkreten Tipps für nächste Woche schreiben.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                MarkdownView(text: reflection)
            }
            if let reflectionError { Text(reflectionError).font(.caption).foregroundStyle(.red) }
            if Secrets.deepSeekEnabled {
                Button(action: generate) {
                    Label(reflection.isEmpty ? "Fazit erstellen" : "Neu erstellen", systemImage: "sparkles")
                }
                .disabled(generating)
            } else {
                Text("Das KI-Fazit läuft über DeepSeek und ist gerade ausgeschaltet (Einstellungen → KI).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
        .onAppear(perform: loadReflection)
    }

    private func loadReflection() {
        reflection = store.reflections.first { $0.weekStart.isSameDay(report.weekStart) }?.aiSummary ?? ""
        reflectionError = nil
    }

    private func generate() {
        generating = true
        reflectionError = nil
        reflection = ""
        let r = report, n = next, ws = report.weekStart
        Task {
            do {
                let text = try await StudyGenerator.weekReflection(report: r, next: n, store: store) { reflection = $0 }
                reflection = text
                if let i = store.reflections.firstIndex(where: { $0.weekStart.isSameDay(ws) }) {
                    store.reflections[i].aiSummary = text
                } else {
                    store.reflections.append(WeekReflection(weekStart: ws, aiSummary: text))
                }
            } catch {
                reflectionError = error.localizedDescription
            }
            generating = false
        }
    }
}

// MARK: Ausblick

private struct WeekOutlookCard: View {
    @Environment(\.isCompactLayout) private var compact
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    let next: WeekReport

    var body: some View {
        let nextStart = next.weekStart
        let demands = Planner(store: store, calendar: calendar).demands(weekStart: nextStart)
        let exams = store.upcomingDeadlines.filter { $0.kind == .klausur && $0.date >= nextStart && $0.date < nextStart.adding(days: 28) }
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Ausblick: KW \(nextStart.weekNumber) · \(Fmt.weekRange(nextStart))", symbol: "binoculars") {
                Button { app.sheet = .planner(nextStart) } label: { Label(compact ? "Planen" : "Lernblöcke planen", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)
            }
            AdaptiveStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fristen").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    if next.deadlines.isEmpty { Text("Keine").font(.callout).foregroundStyle(.secondary) }
                    ForEach(next.deadlines) { d in
                        HStack(spacing: 6) {
                            Image(systemName: d.kind.symbol).foregroundStyle(d.kind.tint).scaledFont(size: 11).accessibilityHidden(true)
                            Text(d.title).font(.callout).lineLimit(1)
                            Spacer()
                            Text(Fmt.dayShort(d.date)).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if !exams.isEmpty {
                        Text("Klausuren in Sicht").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(exams) { e in
                            Text("\(e.title) – \(Fmt.relative(e.date, now: nextStart))").font(.callout)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Belastung").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    LabeledContent("Arbeit", value: Fmt.hours(next.workMinutes))
                    LabeledContent("Vorlesungen", value: Fmt.hours(next.lectureMinutes))
                    LabeledContent("Freie Lernzeit", value: Fmt.hours(next.freeMinutes))
                }
                .font(.callout)
                .frame(width: compact ? nil : 200)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Empfohlene Lernzeit").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    if demands.isEmpty { Text("Ziele bereits eingeplant").font(.callout).foregroundStyle(.secondary) }
                    ForEach(demands) { dm in
                        HStack {
                            ModuleDot(color: store.color(for: dm.id))
                            Text(store.module(dm.id)?.name ?? "").font(.callout).lineLimit(1)
                            Spacer()
                            Text(Fmt.hours(dm.minutes)).font(.callout.monospacedDigit())
                        }
                        .help(dm.reason)
                        .accessibilityElement(children: .combine)
                    }
                    let need = demands.reduce(0) { $0 + $1.minutes }
                    if need > next.freeMinutes && next.freeMinutes > 0 {
                        Label("Mehr Bedarf als freie Zeit – priorisiere!", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var detail: String
    var progress: Double?
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).scaledFont(size: 12, weight: .semibold).foregroundStyle(.secondary)
            Text(value).scaledFont(size: 26, weight: .bold, design: .rounded).tracking(-0.5).monospacedDigit()
            if let progress { BarMeter(value: progress, color: color, height: 5).accessibilityHidden(true) } else { Color.clear.frame(height: 5) }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

struct CheckLine: View {
    var done: Bool
    var title: String
    var detail: String
    var tint: Color
    var toggle: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button { withAnimation(Motion.momentum) { toggle() } } label: {
                Label(done ? "Als offen markieren" : "Erledigt", systemImage: done ? "checkmark.circle.fill" : "circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(done ? .green : .secondary)
                    .scaledFont(size: 15)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
    }
}

// MARK: - Planer

struct PlannerSheet: View {
    @Environment(\.isCompactLayout) private var compact
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(\.dismiss) private var dismiss
    let weekStart: Date
    @State private var proposal: [PlannedBlock] = []
    @State private var included: Set<UUID> = []
    @State private var loaded = false

    var body: some View {
        let planner = Planner(store: store, calendar: calendar)
        let demands = planner.demands(weekStart: weekStart)
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Lernblöcke planen", subtitle: "KW \(weekStart.weekNumber) · \(Fmt.weekRange(weekStart))") {
                Button { recompute() } label: { Label("Neu berechnen", systemImage: "arrow.clockwise") }
            }
            if !calendar.eventsAuthorized {
                Label("Ohne Kalenderzugriff kann Kompass keine freien Zeiten finden.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            AdaptiveStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bedarf").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if demands.isEmpty { Text("Alle Wochenziele sind schon eingeplant oder erfüllt.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(demands) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                ModuleDot(color: store.color(for: d.id))
                                Text(store.module(d.id)?.name ?? "").font(.callout.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text(Fmt.hours(d.minutes)).font(.callout.monospacedDigit())
                            }
                            Text(d.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Divider()
                    Text("Einstellungen: \(Fmt.hm(store.prefs.studyDayStart))–\(Fmt.hm(store.prefs.studyDayEnd)), max. \(Fmt.hours(store.prefs.maxStudyMinutesPerDay))/Tag, Blöcke \(store.prefs.blockMinutes) min")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: compact ? nil : 240)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if proposal.isEmpty {
                            ContentUnavailableView("Kein Vorschlag", systemImage: "calendar.badge.checkmark",
                                                   description: Text("Es gibt keinen offenen Lernbedarf oder keine freie Zeit in dieser Woche."))
                        }
                        ForEach(groupedDays, id: \.self) { day in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Fmt.dayLong(day)).scaledFont(size: 13, weight: .semibold)
                                ForEach(proposal.filter { $0.start.isSameDay(day) }) { b in
                                    let m = store.module(b.moduleID)
                                    let off = !included.contains(b.id)
                                    HStack(spacing: 10) {
                                        CheckToggle(isOn: $included[contains: b.id])
                                        Text("\(Fmt.time(b.start))–\(Fmt.time(b.end))").font(compact ? .subheadline.monospacedDigit() : .callout.monospacedDigit()).fixedSize().frame(minWidth: compact ? 0 : 96, alignment: .leading)
                                        RoundedRectangle(cornerRadius: 2).fill(m?.color.color ?? .gray).frame(width: 3, height: 20)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(m?.name ?? "").font(.callout.weight(.medium))
                                            if !b.focus.isEmpty { Text(b.focus).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        if !compact {
                                            Picker("Modul", selection: moduleBinding(b.id)) {
                                                ForEach(store.activeModules) { m in Text(m.name).tag(m.id) }
                                            }
                                            .labelsHidden().frame(width: 150)
                                        }
                                    }
                                    .opacity(off ? 0.4 : 1)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
            .macFrame(height: 420)
            HStack {
                let chosen = proposal.filter { included.contains($0.id) }
                Text("\(chosen.count) Blöcke · \(Fmt.hours(chosen.reduce(0) { $0 + $1.minutes }))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("In Kalender eintragen") {
                    let saved = planner.commit(chosen, sync: app.sync)
                    app.showToast("\(saved.count) Lernblöcke eingetragen", symbol: "calendar.badge.plus")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .macFrame(width: 820)
        .onAppear { if !loaded { loaded = true; recompute() } }
    }

    private var groupedDays: [Date] {
        Array(Set(proposal.map { $0.start.startOfDay })).sorted()
    }

    private func moduleBinding(_ id: UUID) -> Binding<UUID> {
        Binding(
            get: { proposal.first { $0.id == id }?.moduleID ?? UUID() },
            set: { new in if let i = proposal.firstIndex(where: { $0.id == id }) { proposal[i].moduleID = new; proposal[i].focus = "" } }
        )
    }

    private func recompute() {
        withAnimation(Motion.standard) {
            proposal = Planner(store: store, calendar: calendar).propose(weekStart: weekStart)
            included = Set(proposal.map(\.id))
        }
    }
}
