import SwiftUI
import Charts

struct WeekReviewView: View {
    @Environment(\.isCompactLayout) private var compact
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @State private var weekStart = WeekReviewView.defaultWeek
    @State private var reflection = ""
    @State private var generating = false
    @State private var reflectionError: String?

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
        let planner = Planner(store: store, calendar: calendar)

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Wochenplan", subtitle: "KW \(weekStart.weekNumber) · \(Fmt.weekRange(weekStart))") {
                    HStack(spacing: 2) {
                        Button { withAnimation(Motion.standard) { weekStart = weekStart.adding(weeks: -1) } } label: { Image(systemName: "chevron.left") }
                        Button("Diese Woche") { withAnimation(Motion.standard) { weekStart = Date().startOfWeek } }
                        Button { withAnimation(Motion.standard) { weekStart = weekStart.adding(weeks: 1) } } label: { Image(systemName: "chevron.right") }
                    }
                }

                summaryRow(r)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) { goalsCard(r); shouldCard(r) }.frame(minWidth: 400)
                        VStack(spacing: 20) { loadCard(r); reflectionCard(r, next) }.frame(width: 340)
                    }
                    VStack(spacing: 20) { goalsCard(r); shouldCard(r); loadCard(r); reflectionCard(r, next) }
                }

                outlookCard(next, planner: planner, nextStart: nextStart)
            }
            .pagePadding()
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Wochenplan")
        .inlineNavigationTitle()
        .onChange(of: weekStart) { _, _ in loadReflection() }
        .onAppear(perform: loadReflection)
    }

    // MARK: Zusammenfassung

    private func summaryRow(_ r: WeekReport) -> some View {
        let blocksPlanned = r.lines.reduce(0) { $0 + $1.blocksPlanned }
        let blocksDone = r.lines.reduce(0) { $0 + $1.blocksDone }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            StatTile(value: Fmt.hours(r.totalLogged), label: "gelernt", detail: "Ziel \(Fmt.hours(r.totalGoal))", progress: r.completion, color: .accentColor)
            StatTile(value: "\(blocksDone)/\(blocksPlanned)", label: "Lernblöcke", detail: "erledigt", progress: blocksPlanned > 0 ? Double(blocksDone) / Double(blocksPlanned) : nil, color: .green)
            StatTile(value: "\(r.tasksDone.count)", label: "Aufgaben", detail: "\(r.tasksDue.filter { !$0.done }.count) noch offen", progress: nil, color: .orange)
            StatTile(value: "\(r.deadlines.filter(\.done).count)/\(r.deadlines.count)", label: "Fristen", detail: "diese Woche", progress: r.deadlines.isEmpty ? nil : Double(r.deadlines.filter(\.done).count) / Double(r.deadlines.count), color: .purple)
        }
    }

    // MARK: Ziele je Modul

    private func goalsCard(_ r: WeekReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Geschafft je Modul", symbol: "chart.bar")
            if r.lines.isEmpty {
                Text("Noch keine Module.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(r.lines) { l in
                        BarMark(x: .value("Stunden", Double(l.logged) / 60), y: .value("Modul", l.name))
                            .foregroundStyle(l.color)
                            .cornerRadius(4)
                            .annotation(position: .trailing) {
                                Text("\(Fmt.hours(l.logged)) / \(Fmt.hours(l.goal))").font(.caption2).foregroundStyle(.secondary)
                            }
                        PointMark(x: .value("Ziel", Double(l.goal) / 60), y: .value("Modul", l.name))
                            .symbol {
                                RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.6)).frame(width: 2.5, height: 20)
                            }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel() } }
                .chartLegend(.hidden)
                .frame(height: CGFloat(max(1, r.lines.count)) * 34 + 24)
                Text("Strich = Wochenziel").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    // MARK: Soll

    private func shouldCard(_ r: WeekReport) -> some View {
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
            if !behind.isEmpty && weekStart <= Date() {
                Divider()
                ForEach(behind) { l in
                    HStack {
                        ModuleDot(color: l.color)
                        Text(l.name).font(.callout)
                        Spacer()
                        Text("noch \(Fmt.hours(l.goal - l.logged))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }

    // MARK: Belastung

    private func loadCard(_ r: WeekReport) -> some View {
        let items: [(String, Int, Color)] = [
            ("Arbeit", r.workMinutes, .gray), ("Vorlesungen & Übungen", r.lectureMinutes, .blue),
            ("Andere Termine", r.eventMinutes, .purple), ("Gelernt", r.totalLogged, .green)
        ]
        let limit = Int(store.prefs.workWeeklyLimitHours * 60)
        let total = max(1, items.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Zeitbudget", symbol: "clock")
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(items, id: \.0) { it in
                        if it.1 > 0 {
                            RoundedRectangle(cornerRadius: 3).fill(it.2.gradient)
                                .frame(width: max(4, (geo.size.width - 8) * CGFloat(it.1) / CGFloat(total)))
                        }
                    }
                }
            }
            .frame(height: 12)
            ForEach(items, id: \.0) { it in
                HStack {
                    Circle().fill(it.2).frame(width: 7, height: 7)
                    Text(it.0).font(.callout)
                    Spacer()
                    Text(Fmt.hours(it.1)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if r.workLogged > 0 || r.otherLogged > 0 {
                Divider()
                HStack {
                    Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary)
                    Text("Arbeit erfasst").font(.callout)
                    Spacer()
                    Text(Fmt.hours(r.workLogged)).font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(limit > 0 && r.workLogged > limit && app.isLectureWeek(weekStart) ? .orange : .primary)
                }
                .onTapGesture { app.selection = .time }
            }
            if r.freeMinutes > 0 {
                Divider()
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                    Text("Noch frei im Lernfenster").font(.callout)
                    Spacer()
                    Text(Fmt.hours(r.freeMinutes)).font(.callout.monospacedDigit().weight(.semibold))
                }
            }
        }
        .card()
    }

    // MARK: Fazit

    private func reflectionCard(_ r: WeekReport, _ next: WeekReport) -> some View {
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
            Button {
                generate(r, next)
            } label: { Label(reflection.isEmpty ? "Fazit erstellen" : "Neu erstellen", systemImage: "sparkles") }
                .disabled(generating)
        }
        .card()
    }

    private func loadReflection() {
        reflection = store.reflections.first { $0.weekStart.isSameDay(weekStart) }?.aiSummary ?? ""
        reflectionError = nil
    }

    private func generate(_ r: WeekReport, _ next: WeekReport) {
        generating = true
        reflectionError = nil
        reflection = ""
        let ws = weekStart
        Task {
            do {
                let text = try await StudyGenerator.weekReflection(report: r, next: next, store: store) { reflection = $0 }
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

    // MARK: Ausblick

    private func outlookCard(_ next: WeekReport, planner: Planner, nextStart: Date) -> some View {
        let demands = planner.demands(weekStart: nextStart)
        let exams = store.upcomingDeadlines.filter { $0.kind == .klausur && $0.date >= nextStart && $0.date < nextStart.adding(days: 28) }
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Ausblick: KW \(nextStart.weekNumber) · \(Fmt.weekRange(nextStart))", symbol: "binoculars") {
                Button { app.sheet = .planner(nextStart) } label: { Label(compact ? "Planen" : "Lernblöcke planen", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)
            }
            AdaptiveStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fristen").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if next.deadlines.isEmpty { Text("Keine").font(.callout).foregroundStyle(.secondary) }
                    ForEach(next.deadlines) { d in
                        HStack(spacing: 6) {
                            Image(systemName: d.kind.symbol).foregroundStyle(d.kind.tint).font(.system(size: 11))
                            Text(d.title).font(.callout).lineLimit(1)
                            Spacer()
                            Text(Fmt.dayShort(d.date)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !exams.isEmpty {
                        Text("Klausuren in Sicht").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(exams) { e in
                            Text("\(e.title) – \(Fmt.relative(e.date, now: nextStart))").font(.callout)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Belastung").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LabeledContent("Arbeit", value: Fmt.hours(next.workMinutes))
                    LabeledContent("Vorlesungen", value: Fmt.hours(next.lectureMinutes))
                    LabeledContent("Freie Lernzeit", value: Fmt.hours(next.freeMinutes))
                }
                .font(.callout)
                .frame(width: compact ? nil : 200)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Empfohlene Lernzeit").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if demands.isEmpty { Text("Ziele bereits eingeplant").font(.callout).foregroundStyle(.secondary) }
                    ForEach(demands) { dm in
                        HStack {
                            ModuleDot(color: store.color(for: dm.id))
                            Text(store.module(dm.id)?.name ?? "").font(.callout).lineLimit(1)
                            Spacer()
                            Text(Fmt.hours(dm.minutes)).font(.callout.monospacedDigit())
                        }
                        .help(dm.reason)
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
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).tracking(-0.5).monospacedDigit()
            if let progress { BarMeter(value: progress, color: color, height: 5) } else { Color.clear.frame(height: 5) }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
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
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? .green : .secondary)
                    .font(.system(size: 15))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 3, height: 22)
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
    @State private var excluded: Set<UUID> = []
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
                                Text(Fmt.dayLong(day)).font(.system(size: 13, weight: .semibold))
                                ForEach(proposal.filter { $0.start.isSameDay(day) }) { b in
                                    let m = store.module(b.moduleID)
                                    let off = excluded.contains(b.id)
                                    HStack(spacing: 10) {
                                        CheckToggle(isOn: Binding(get: { !off }, set: { on in if on { excluded.remove(b.id) } else { excluded.insert(b.id) } }))
                                        Text("\(Fmt.time(b.start))–\(Fmt.time(b.end))").font(compact ? .subheadline.monospacedDigit() : .callout.monospacedDigit()).fixedSize().frame(minWidth: compact ? 0 : 96, alignment: .leading)
                                        RoundedRectangle(cornerRadius: 2).fill(m?.color.color ?? .gray).frame(width: 3, height: 20)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(m?.name ?? "").font(.callout.weight(.medium))
                                            if !b.focus.isEmpty { Text(b.focus).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        if !compact {
                                            Picker("", selection: moduleBinding(b.id)) {
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
                let count = proposal.count - excluded.count
                Text("\(count) Blöcke · \(Fmt.hours(proposal.filter { !excluded.contains($0.id) }.reduce(0) { $0 + $1.minutes }))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("In Kalender eintragen") {
                    let chosen = proposal.filter { !excluded.contains($0.id) }
                    let saved = planner.commit(chosen, sync: app.sync)
                    app.showToast("\(saved.count) Lernblöcke eingetragen", symbol: "calendar.badge.plus")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
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
            excluded = []
        }
    }
}
